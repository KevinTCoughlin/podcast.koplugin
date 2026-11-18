--[[--
A small on-disk cache for feed bodies, so opening a show's episode list is a
conditional request -- or no request at all -- rather than a full download.

For each feed it keeps the body and what the server said about it: ETag,
Last-Modified, when it was fetched, and the max-age from Cache-Control. `get`
then behaves like `Fetch:get` with three outcomes:

  * **Fresh** (fetched less than max-age ago): the cached body, no request.
  * **Stale, with validators**: If-None-Match / If-Modified-Since are sent, and
    a 304 returns the cached body and restarts the max-age clock.
  * **Anything else**: a plain request, whose 200 replaces the entry.

Freshness is capped at MAX_FRESH_SECONDS, so a feed misconfigured with a
year-long max-age still updates daily, and a fetch time in the future (a
device clock that was reset) counts as stale. A response with `no-store`, or
with neither validators nor a max-age, is not kept: there would be nothing to
reuse it with.

Layout: one `index.lua` (a Lua literal, like the library) holding the metadata,
and one body file per feed named by `Library.feed_tag`. The body is written
before the index and its size recorded there, so a write interrupted between the
two -- a subprocess killed by a tap -- reads as a missing entry, never as a
truncated feed. A missing, corrupt or mismatched cache is an empty cache.

Size is bounded by `prune`: only feeds still subscribed to are kept.
]]

local Fetch = require("net.fetch")
local Library = require("library")

local FeedCache = {}
FeedCache.__index = FeedCache

local INDEX_VERSION = 1
local MAX_FRESH_SECONDS = 24 * 60 * 60

FeedCache.MAX_FRESH_SECONDS = MAX_FRESH_SECONDS

--- `opts.dir` defaults to KOReader's cache directory (see
-- Library.default_cache_dir); `opts.now` is injectable for tests.
function FeedCache.new(opts)
    opts = opts or {}
    local self = setmetatable({
        dir = opts.dir or Library.default_cache_dir(),
        now = opts.now or os.time,
        feeds = {},
    }, FeedCache)
    self:load()
    return self
end

function FeedCache:_index_path()
    return self.dir .. "/index.lua"
end

--- An index entry is only trusted if every field has the type it should; a
-- hand-edited or half-written index must not crash a fetch.
local function valid_entry(entry)
    return type(entry) == "table"
        and type(entry.file) == "string" and entry.file:match("^[%w%-]+%.xml$") ~= nil
        and type(entry.size) == "number"
        and type(entry.fetched_at) == "number"
        and (entry.max_age == nil or type(entry.max_age) == "number")
        and (entry.etag == nil or type(entry.etag) == "string")
        and (entry.last_modified == nil or type(entry.last_modified) == "string")
        and (entry.final_url == nil or type(entry.final_url) == "string")
end

function FeedCache:load()
    self.feeds = {}
    local chunk = loadfile(self:_index_path())
    if not chunk then return false end
    -- The index is data; give it nothing to call.
    if setfenv then setfenv(chunk, {}) end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or data.version ~= INDEX_VERSION
        or type(data.feeds) ~= "table" then
        return false
    end
    for url, entry in pairs(data.feeds) do
        if type(url) == "string" and valid_entry(entry) then self.feeds[url] = entry end
    end
    return true
end

function FeedCache:save()
    return Library.write_atomically(self:_index_path(),
        "-- podcast.koplugin feed cache. Safe to delete.\nreturn " ..
        Library.serialize({ version = INDEX_VERSION, feeds = self.feeds }) .. "\n")
end

--- The cached body for `url`, or nil when there is none or it does not match
-- what the index recorded.
function FeedCache:_body(url)
    local entry = self.feeds[url]
    if not entry then return nil end
    local handle = io.open(self.dir .. "/" .. entry.file, "rb")
    local body = handle and handle:read("*a")
    if handle then handle:close() end
    if not body or #body ~= entry.size then return nil end
    return body
end

--- True when `url` may be served from the cache without asking the server.
-- Checks the index and the body file's size, not its contents.
function FeedCache:is_fresh(url)
    local entry = self.feeds[url]
    if not entry or not entry.max_age then return false end
    local age = self.now() - entry.fetched_at
    if age < 0 then return false end
    if age >= math.min(entry.max_age, MAX_FRESH_SECONDS) then return false end
    return Fetch.file_size(self.dir .. "/" .. entry.file) == entry.size
end

function FeedCache:_forget(url)
    local entry = self.feeds[url]
    if not entry then return end
    os.remove(self.dir .. "/" .. entry.file)
    self.feeds[url] = nil
end

--- Records a 200. Not kept when the server forbade it, or when nothing about
-- the response would let it be reused.
function FeedCache:_store(url, body, info)
    if info.no_store or not (info.etag or info.last_modified or info.max_age) then
        self:_forget(url)
        return
    end
    local file = Library.feed_tag(url) .. ".xml"
    if not Library.write_atomically(self.dir .. "/" .. file, body) then
        -- Cannot write the body: drop the entry rather than point at stale bytes.
        self:_forget(url)
        return
    end
    self.feeds[url] = {
        file = file,
        size = #body,
        final_url = info.url,
        etag = info.etag,
        last_modified = info.last_modified,
        max_age = info.max_age,
        fetched_at = self.now(),
    }
end

--- Fetches `url` through the cache. Same return shape as `Fetch:get` --
-- `body, err, code, info` -- with `info.from_cache` set to "fresh" (no request
-- was made; `code` is nil) or "revalidated" (the server said 304).
-- A permanent redirect moves the entry to the new URL along with the
-- subscription. Saves the index when it changed.
function FeedCache:get(fetch, url, opts)
    opts = opts or {}
    local cached = self:_body(url)
    if not cached then self:_forget(url) end

    if cached and self:is_fresh(url) then
        local entry = self.feeds[url]
        return cached, nil, nil, {
            url = entry.final_url or url, etag = entry.etag, last_modified = entry.last_modified,
            from_cache = "fresh",
        }
    end

    local entry = cached and self.feeds[url]
    local request = {}
    for key, value in pairs(opts) do request[key] = value end
    -- Validators only when there is a body to fall back on: a 304 with
    -- nothing cached would leave nothing to show.
    request.etag = entry and entry.etag or nil
    request.last_modified = entry and entry.last_modified or nil

    local body, err, code, info = fetch:get(url, request)
    info = info or {}
    local key = info.moved_to or url

    if err == Fetch.NOT_MODIFIED then
        if not entry then return nil, "HTTP 304 with nothing cached", code, info end
        -- A 304 carries updated metadata; keep what it does not mention.
        entry.etag = info.etag or entry.etag
        entry.last_modified = info.last_modified or entry.last_modified
        if info.max_age then entry.max_age = info.max_age end
        entry.final_url = info.url or entry.final_url
        entry.fetched_at = self.now()
        if key ~= url then
            self.feeds[url] = nil
            self.feeds[key] = entry
        end
        if info.no_store then self:_forget(key) end
        self:save()
        info.from_cache = "revalidated"
        return cached, nil, code, info
    end

    if body then
        if key ~= url then self:_forget(url) end
        self:_store(key, body, info)
        self:save()
    end
    return body, err, code, info
end

--- Drops every entry whose URL is not in `keep` (a list of feed URLs), so the
-- cache never holds more than the current subscriptions. Saves if it changed.
function FeedCache:prune(keep)
    local wanted = {}
    for _, url in ipairs(keep or {}) do wanted[url] = true end
    local changed = false
    for url in pairs(self.feeds) do
        if not wanted[url] then
            self:_forget(url)
            changed = true
        end
    end
    if changed then self:save() end
    return changed
end

return FeedCache
