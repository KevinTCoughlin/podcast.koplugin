--[[--
Subscriptions and per-episode state.

Persisted as a Lua table literal, which is the same thing KOReader's
LuaSettings writes -- so the store works identically under the CLI harness and
on device, and the file is readable and repairable by hand when something goes
wrong on a device you cannot debug.

Episode state is keyed by feed URL and guid and kept **separately from the
feed**. A refresh replaces the episode list wholesale; what must survive it is
the part the user created: what has been played, how far in, and what is
downloaded. Merging that into the feed data would lose it the first time a
publisher re-issued an item.

The feed URL is part of the key because a guid is only unique within its feed:
two shows built from the same template both have an episode "1". State lives in
`episodes_by_feed[feed_url][guid]`. Libraries written before that keyed it by
guid alone, in `episode_state[guid]`; those entries are claimed by the first
feed that asks for the guid, and moved across. An episode table without a
`feed_url` still reads and writes the old guid-only table.
]]

local Library = {}
Library.__index = Library

local INDENT = "  "

--- Serializes a table of plain data as a Lua literal.
-- Only handles what this store holds: strings, numbers, booleans, and tables
-- thereof. Anything else is a bug, not something to serialize defensively.
local function serialize(value, depth)
    depth = depth or 1
    local value_type = type(value)

    if value_type == "string" then return string.format("%q", value) end
    if value_type == "number" or value_type == "boolean" then return tostring(value) end
    if value_type ~= "table" then return "nil" end

    local pad = string.rep(INDENT, depth)
    local close_pad = string.rep(INDENT, depth - 1)
    local parts = {}

    -- Array part first, so lists round-trip as lists.
    local count = #value
    for index = 1, count do
        parts[#parts + 1] = pad .. serialize(value[index], depth + 1)
    end

    local keys = {}
    for key in pairs(value) do
        if not (type(key) == "number" and key >= 1 and key <= count and key % 1 == 0) then
            keys[#keys + 1] = key
        end
    end
    -- Sorted so the file is stable across writes and diffable.
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = string.format("%s[%s] = %s",
            pad, string.format("%q", tostring(key)), serialize(value[key], depth + 1))
    end

    if #parts == 0 then return "{}" end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. close_pad .. "}"
end

Library.serialize = serialize

local function default_path()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then return DataStorage:getSettingsDir() .. "/podcast.lua" end
    return (os.getenv("KOPOD_HOME") or (os.getenv("HOME") or ".") .. "/.kopod") .. "/library.lua"
end

--- Where the episode-list cache lives: KOReader's cache directory on device,
-- next to the library under the CLI harness.
function Library.default_cache_dir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then return DataStorage:getDataDir() .. "/cache/podcast-feeds" end
    return (os.getenv("KOPOD_HOME") or (os.getenv("HOME") or ".") .. "/.kopod") .. "/feeds"
end

local function default_download_dir()
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then return DataStorage:getDataDir() .. "/podcasts" end
    return (os.getenv("KOPOD_HOME") or (os.getenv("HOME") or ".") .. "/.kopod") .. "/episodes"
end

function Library.new(opts)
    opts = opts or {}
    local self = setmetatable({
        path = opts.path or default_path(),
        download_dir = opts.download_dir or default_download_dir(),
        data = { subscriptions = {}, episode_state = {}, episodes_by_feed = {} },
    }, Library)
    self:load()
    return self
end

function Library:load()
    local chunk = loadfile(self.path)
    if not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return false end
    self.data.subscriptions = data.subscriptions or {}
    self.data.episode_state = data.episode_state or {}
    self.data.episodes_by_feed = data.episodes_by_feed or {}
    return true
end

--- Writes `text` to `path` through a temporary file and a rename, creating the
-- directory on demand, so a crash or a killed subprocess mid-write leaves the
-- previous file intact rather than half of a new one.
local function write_atomically(path, text)
    -- There is no mkdir in plain Lua.
    local dir = path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null") end

    local tmp = path .. ".tmp"
    local handle = io.open(tmp, "wb")
    if not handle then return false end
    local ok = handle:write(text)
    handle:close()
    if not ok then
        os.remove(tmp)
        return false
    end
    return os.rename(tmp, path)
end

Library.write_atomically = write_atomically

function Library:save()
    -- The legacy guid-only table empties as feeds claim its entries; once it
    -- has, stop writing it.
    local legacy = self.data.episode_state
    if next(legacy) == nil then self.data.episode_state = nil end
    local text = "-- podcast.koplugin library. Edit with care.\nreturn " ..
        serialize(self.data) .. "\n"
    self.data.episode_state = legacy
    return write_atomically(self.path, text)
end

function Library:subscriptions()
    return self.data.subscriptions
end

--- The subscribed feed URLs, as a list: what the feed cache is pruned to.
function Library:feed_urls()
    local urls = {}
    for index, subscription in ipairs(self.data.subscriptions) do urls[index] = subscription.url end
    return urls
end

function Library:find(url)
    for index, subscription in ipairs(self.data.subscriptions) do
        if subscription.url == url then return subscription, index end
    end
    return nil
end

--- Adds a subscription, or updates the title of an existing one.
-- Returns subscription, was_new.
function Library:subscribe(url, channel)
    local existing = self:find(url)
    if existing then
        if channel and channel.title then existing.title = channel.title end
        return existing, false
    end
    local subscription = {
        url = url,
        title = (channel and channel.title) or url,
        author = channel and channel.author,
        image = channel and channel.image,
        added_at = os.time(),
        last_refreshed = nil,
        episode_count = 0,
    }
    table.insert(self.data.subscriptions, subscription)
    return subscription, true
end

function Library:unsubscribe(url)
    local _, index = self:find(url)
    if not index then return false end
    table.remove(self.data.subscriptions, index)
    return true
end

--- Conditional-request validators from the last full refresh, as the opts
-- `Fetch:get` takes.
function Library:validators(url)
    local subscription = self:find(url)
    if not subscription then return {} end
    return { etag = subscription.etag, last_modified = subscription.last_modified }
end

--- Moves a subscription to a new URL after a permanent redirect, taking its
-- episode state along. If the new URL is already a subscription of its own,
-- the two are merged into that one. Returns the subscription now at `new_url`.
function Library:rename_feed(old_url, new_url)
    local subscription, index = self:find(old_url)
    if not subscription or old_url == new_url then return subscription end

    local by_feed = self.data.episodes_by_feed
    local moving = by_feed[old_url]
    by_feed[old_url] = nil
    if moving then
        local target = by_feed[new_url] or {}
        for guid, state in pairs(moving) do
            if target[guid] == nil then target[guid] = state end
        end
        by_feed[new_url] = target
    end

    local existing = self:find(new_url)
    if existing then
        table.remove(self.data.subscriptions, index)
        return existing
    end
    subscription.url = new_url
    -- Validators belong to the old URL's responses.
    subscription.etag, subscription.last_modified = nil, nil
    return subscription
end

--- Applies what a refresh learned about a show.
--
-- `info.count` is the episode count, or nil when the feed was parsed with a
-- max_episodes cap -- recording a capped count would tell the user a
-- thousand-episode show has fifteen. Taking a count rather than a feed is what
-- lets a bulk refresh report counts without carrying every episode table back
-- across a subprocess boundary.
--
-- Also carries what the fetch learned: `info.moved_to` renames the
-- subscription (see rename_feed); `info.not_modified` means the server said 304,
-- so only the refresh time changes; and when `info.validators` is set,
-- `info.etag` and `info.last_modified` replace the stored pair -- together, so
-- a server that stops sending one does not leave a stale one behind. Only a
-- full, uncapped refresh should store validators: a 304 later keeps the count
-- that refresh recorded.
function Library:apply_refresh(url, info)
    info = info or {}
    if info.moved_to then
        self:rename_feed(url, info.moved_to)
        url = info.moved_to
    end
    local subscription = self:find(url)
    if not subscription then return end
    subscription.last_refreshed = os.time()
    if info.validators then
        subscription.etag = info.etag
        subscription.last_modified = info.last_modified
    end
    if info.not_modified then return subscription end
    if info.count then subscription.episode_count = info.count end
    if info.title then subscription.title = info.title end
    subscription.author = subscription.author or info.author
    subscription.image = subscription.image or info.image
    return subscription
end

--- Convenience wrapper for callers that already hold a parsed feed.
-- `complete` must be false when the parse was capped.
function Library:record_refresh(url, feed, complete)
    self:apply_refresh(url, {
        title = feed.channel.title,
        author = feed.channel.author,
        image = feed.channel.image,
        count = complete and #feed.episodes or nil,
    })
end

--- Looks up an episode's state, migrating a legacy guid-only entry into its
-- feed on the way. With `create`, a missing entry is made; otherwise nil.
local function lookup(self, episode, create)
    local guid = episode and episode.guid
    if not guid then return nil end
    local legacy = self.data.episode_state
    local feed_url = episode.feed_url
    if not feed_url then
        if create and not legacy[guid] then legacy[guid] = {} end
        return legacy[guid]
    end

    local by_feed = self.data.episodes_by_feed
    local feed = by_feed[feed_url]
    local state = feed and feed[guid]
    if state then return state end

    state = legacy[guid]
    if state then
        legacy[guid] = nil
    elseif create then
        state = {}
    else
        return nil
    end
    if not feed then
        feed = {}
        by_feed[feed_url] = feed
    end
    feed[guid] = state
    return state
end

--- Per-episode state, created on first access. Takes the episode table, since
-- the key is its feed_url and guid together.
function Library:episode(episode)
    return lookup(self, episode, true) or {}
end

--- A short, stable tag for a feed URL, so two feeds' episode "1" do not
-- download to the same file. Not cryptographic; it only has to differ.
local function feed_tag(feed_url)
    local hash = 5381
    for index = 1, #feed_url do
        hash = (hash * 33 + feed_url:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

Library.feed_tag = feed_tag

--- Where an episode's audio lives once downloaded. Derived from the feed and
-- guid so it is stable across refreshes, and sanitised because a guid is
-- publisher-supplied and may contain anything at all -- including `../`.
function Library:episode_path(episode)
    local stem = tostring(episode.guid or episode.url)
        :gsub("[^%w%-%._]", "_")
        :sub(-96)
    if episode.feed_url then stem = feed_tag(episode.feed_url) .. "-" .. stem end
    local extension = (tostring(episode.url):gsub("[?#].*$", ""):match("%.([%w]+)$") or "mp3")
    if #extension > 5 then extension = "mp3" end
    return self.download_dir .. "/" .. stem .. "." .. extension:lower()
end

function Library:is_downloaded(episode)
    local state = lookup(self, episode)
    if not state or not state.path then return false end
    local handle = io.open(state.path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Library:mark_downloaded(episode, path, size)
    local state = self:episode(episode)
    state.path = path
    state.size = size
    state.downloaded_at = os.time()
end

function Library:forget_download(episode)
    local state = lookup(self, episode)
    if not state then return end
    if state.path then os.remove(state.path) end
    state.path, state.size, state.downloaded_at = nil, nil, nil
end

--- Playback position, in whole seconds. This is the field that makes a podcast
-- app usable, and the reason episode state is not thrown away on refresh.
function Library:set_position(episode, seconds)
    local state = self:episode(episode)
    state.position = math.max(0, math.floor(tonumber(seconds) or 0))
    -- Within a minute of the end counts as finished; chasing the exact last
    -- second means an episode never leaves the "in progress" list.
    if episode.duration and episode.duration > 0
        and state.position >= (episode.duration - 60) then
        state.played = true
    end
end

function Library:position(episode)
    local state = lookup(self, episode)
    return state and state.position or 0
end

function Library:is_played(episode)
    local state = lookup(self, episode)
    return state ~= nil and state.played == true
end

function Library:set_played(episode, played)
    local state = self:episode(episode)
    state.played = played and true or nil
    if played then state.position = nil end
end

return Library
