--[[--
Subscriptions and per-episode state.

Persisted as a Lua table literal, which is the same thing KOReader's
LuaSettings writes -- so the store works identically under the CLI harness and
on device, and the file is readable and repairable by hand when something goes
wrong on a device you cannot debug.

Episode state is keyed by guid and kept **separately from the feed**. A refresh
replaces the episode list wholesale; what must survive it is the part the user
created: what has been played, how far in, and what is downloaded. Merging that
into the feed data would lose it the first time a publisher re-issued an item.
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
        data = { subscriptions = {}, episode_state = {} },
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
    return true
end

function Library:save()
    -- Create the directory on demand; there is no mkdir in plain Lua.
    local dir = self.path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "' 2>/dev/null") end

    local tmp = self.path .. ".tmp"
    local handle = io.open(tmp, "w")
    if not handle then return false end
    handle:write("-- podcast.koplugin library. Edit with care.\nreturn ",
        serialize(self.data), "\n")
    handle:close()
    return os.rename(tmp, self.path)
end

function Library:subscriptions()
    return self.data.subscriptions
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

--- Applies what a refresh learned about a show.
--
-- `info.count` is the episode count, or nil when the feed was parsed with a
-- max_episodes cap -- recording a capped count would tell the user a
-- thousand-episode show has fifteen. Taking a count rather than a feed is what
-- lets a bulk refresh report counts without carrying every episode table back
-- across a subprocess boundary.
function Library:apply_refresh(url, info)
    local subscription = self:find(url)
    if not subscription then return end
    info = info or {}
    subscription.last_refreshed = os.time()
    if info.count then subscription.episode_count = info.count end
    if info.title then subscription.title = info.title end
    subscription.author = subscription.author or info.author
    subscription.image = subscription.image or info.image
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

--- Per-episode state, created on first access.
function Library:episode(guid)
    if not guid then return {} end
    local state = self.data.episode_state[guid]
    if not state then
        state = {}
        self.data.episode_state[guid] = state
    end
    return state
end

--- Where an episode's audio lives once downloaded. Derived from the guid so it
-- is stable across refreshes, and sanitised because a guid is publisher-supplied
-- and may contain anything at all -- including `../`.
function Library:episode_path(episode)
    local stem = tostring(episode.guid or episode.url)
        :gsub("[^%w%-%._]", "_")
        :sub(-96)
    local extension = (tostring(episode.url):gsub("[?#].*$", ""):match("%.([%w]+)$") or "mp3")
    if #extension > 5 then extension = "mp3" end
    return self.download_dir .. "/" .. stem .. "." .. extension:lower()
end

function Library:is_downloaded(episode)
    local state = self.data.episode_state[episode.guid]
    if not state or not state.path then return false end
    local handle = io.open(state.path, "rb")
    if not handle then return false end
    handle:close()
    return true
end

function Library:mark_downloaded(episode, path, size)
    local state = self:episode(episode.guid)
    state.path = path
    state.size = size
    state.downloaded_at = os.time()
end

function Library:forget_download(episode)
    local state = self.data.episode_state[episode.guid]
    if not state then return end
    if state.path then os.remove(state.path) end
    state.path, state.size, state.downloaded_at = nil, nil, nil
end

--- Playback position, in whole seconds. This is the field that makes a podcast
-- app usable, and the reason episode state is not thrown away on refresh.
function Library:set_position(episode, seconds)
    local state = self:episode(episode.guid)
    state.position = math.max(0, math.floor(tonumber(seconds) or 0))
    -- Within a minute of the end counts as finished; chasing the exact last
    -- second means an episode never leaves the "in progress" list.
    if episode.duration and episode.duration > 0
        and state.position >= (episode.duration - 60) then
        state.played = true
    end
end

function Library:position(episode)
    local state = self.data.episode_state[episode.guid]
    return state and state.position or 0
end

function Library:is_played(episode)
    local state = self.data.episode_state[episode.guid]
    return state ~= nil and state.played == true
end

function Library:set_played(episode, played)
    local state = self:episode(episode.guid)
    state.played = played and true or nil
    if played then state.position = nil end
end

return Library
