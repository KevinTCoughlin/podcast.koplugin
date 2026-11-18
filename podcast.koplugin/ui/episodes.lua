--[[--
The episode list, and the actions on an episode.

Two things shape this file, both of them device constraints rather than taste.

**Feeds are fetched and parsed in a subprocess.** `Trapper:dismissableRunInSubprocess`
forks, so a multi-megabyte parse cannot block the reader and the user can
dismiss it. It also caps the episode count: a 2983-episode feed serialized back
across the process boundary would be slow for no purpose, since nobody scrolls
that far.

**Downloads are dismissable, and dismissing is safe.** The subprocess is killed
with SIGKILL, which leaves a partial file on disk -- and that is exactly what
`net/fetch.lua` resumes from on the next attempt. Cancelling a 200 MB download
at 90% costs nothing.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")

local DateTime = require("feed.datetime")
local FeedCache = require("net.feedcache")
local Fetch = require("net.fetch")
local NowPlaying = require("ui/nowplaying")
local Parser = require("feed.parser")

local Episodes = {}
Episodes.__index = Episodes

--- How many episodes to pull into the list. Enough to scroll for a while,
-- small enough that the parse and the hand-back stay cheap.
local EPISODE_LIMIT = 100

function Episodes.new(opts)
    return setmetatable({
        library = opts.library,
        subscription = opts.subscription,
        get_player = opts.get_player,
        on_play = opts.on_play,
        fetch = Fetch.new(nil, { user_agent = opts.user_agent }),
        cache_dir = opts.cache_dir,
    }, Episodes)
end

local function show_error(message)
    UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 5 })
end

function Episodes:_close_menu()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

--- The subtitle for a row. Everything here is what someone needs to decide
-- whether to tap: when, how long, whether it is already on the device, and how
-- far in they got.
function Episodes:_describe(episode)
    local parts = {}
    if episode.published then
        parts[#parts + 1] = os.date("!%Y-%m-%d", episode.published)
    end
    local duration = DateTime.format_duration(episode.duration)
    if duration then parts[#parts + 1] = duration end

    if self.library:is_played(episode) then
        parts[#parts + 1] = _("played")
    else
        local position = self.library:position(episode)
        if position > 0 then
            parts[#parts + 1] = _("at ") .. (DateTime.format_duration(position) or "0:00")
        end
    end
    if self.library:is_downloaded(episode) then
        parts[#parts + 1] = _("downloaded")
    elseif episode.size then
        parts[#parts + 1] = string.format("%.0f MB", episode.size / 1048576)
    end
    return table.concat(parts, "  \194\183  ")
end

--- Fetches and parses the feed in a subprocess. Returns the feed or nil.
-- The fetch goes through the feed cache: a fresh copy costs no request, a
-- stale one a conditional request (see net/feedcache.lua).
function Episodes:_load_feed()
    local url = self.subscription.url
    local fetch_kind = self.fetch.kind
    local user_agent = self.fetch.user_agent
    local cache_dir = self.cache_dir
    local keep = self.library:feed_urls()

    local completed, result = Trapper:dismissableRunInSubprocess(function()
        -- Runs in the forked child: no UIManager, no settings, no widgets.
        -- The cache is plain files, so writing it from here is safe.
        local ChildFeedCache = require("net.feedcache")
        local ChildFetch = require("net.fetch")
        local ChildParser = require("feed.parser")
        local cache = ChildFeedCache.new{ dir = cache_dir }
        local body, err, _code, info = cache:get(
            ChildFetch.new(fetch_kind, { user_agent = user_agent }), url, { timeout = 45 })
        if info and info.moved_to then keep[#keep + 1] = info.moved_to end
        cache:prune(keep)
        if not body then return { error = tostring(err) } end
        local feed_url = info and info.moved_to or url
        local feed, parse_err = ChildParser.parse(body, {
            max_episodes = EPISODE_LIMIT,
            base_url = info and info.url or url,
            feed_url = feed_url,
        })
        if not feed then return { error = tostring(parse_err) } end
        feed.moved_to = info and info.moved_to
        return feed
    end, _("Loading episodes…\n\nTap to cancel."))

    if not completed then return nil end
    if not result then
        show_error(_("Could not load this feed."))
        return nil
    end
    if result.error then
        show_error(_("Could not load this feed.\n\n") .. result.error)
        return nil
    end
    return result
end

function Episodes:show()
    local function load_and_show()
        Trapper:wrap(function()
            local feed = self:_load_feed()
            if not feed then return end

            if feed.moved_to then
                -- Permanently moved: follow it, episode state and all.
                self.subscription = self.library:rename_feed(self.subscription.url, feed.moved_to)
                    or self.subscription
            end
            self.library:record_refresh(self.subscription.url, feed, false)
            self.library:save()
            self:_show_list(feed)
        end)
    end
    -- A fresh cached copy needs no network, so do not wake the Wi-Fi for it.
    if FeedCache.new{ dir = self.cache_dir }:is_fresh(self.subscription.url) then
        load_and_show()
    else
        NetworkMgr:runWhenOnline(load_and_show)
    end
end

function Episodes:_show_list(feed)
    if #feed.episodes == 0 then
        show_error(_("This feed has no playable episodes."))
        return
    end

    local items = {}
    for _index, episode in ipairs(feed.episodes) do
        items[#items + 1] = {
            text = episode.title,
            help_text = self:_describe(episode),
            episode = episode,
        }
    end

    self:_close_menu()
    self.menu = Menu:new{
        title = feed.channel.title or self.subscription.title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            self:_show_actions(item.episode, feed)
            return true
        end,
        close_callback = function() self.menu = nil end,
    }
    UIManager:show(self.menu)
end

--- Rebuilds the list in place so a download or a position change is visible
-- without re-fetching the feed.
--
-- `focus_guid` is the episode that was just acted on; switchItemTable's third
-- argument focuses an item *index*, which is what keeps the user on the page
-- they were looking at instead of throwing them back to the top of a
-- hundred-item list.
function Episodes:_refresh_list(feed, focus_guid)
    if not self.menu then return end
    local items, focus_index = {}, nil
    for index, episode in ipairs(feed.episodes) do
        items[#items + 1] = {
            text = episode.title,
            help_text = self:_describe(episode),
            episode = episode,
        }
        if focus_guid and episode.guid == focus_guid then focus_index = index end
    end
    self.menu:switchItemTable(nil, items, focus_index)
end

function Episodes:_download(episode, feed)
    local path = self.library:episode_path(episode)
    local download_dir = self.library.download_dir
    local url = episode.url
    local fetch_kind = self.fetch.kind
    local user_agent = self.fetch.user_agent

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local message = _("Downloading…\n\n") .. episode.title ..
                _("\n\nTap to cancel. A cancelled download resumes where it stopped.")

            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local lfs = require("libs/libkoreader-lfs")
                if lfs.attributes(download_dir, "mode") ~= "directory" then
                    lfs.mkdir(download_dir)
                end
                local ChildFetch = require("net.fetch")
                local size, err = ChildFetch.new(fetch_kind, { user_agent = user_agent })
                    :download(url, path)
                return { size = size, error = err and tostring(err) or nil }
            end, message)

            if not completed then
                -- Dismissed: the partial file is deliberately left in place.
                show_error(_("Download cancelled. It will resume where it stopped."))
                return
            end
            if not result or result.error then
                show_error(_("Download failed.\n\n") ..
                    tostring(result and result.error or "unknown error"))
                return
            end

            self.library:mark_downloaded(episode, path, result.size)
            self.library:save()
            UIManager:show(InfoMessage:new{
                text = string.format(_("Downloaded %.1f MB."), result.size / 1048576),
                timeout = 3,
            })
            self:_refresh_list(feed, episode.guid)
        end)
    end)
end

function Episodes:_play(episode, resume)
    local player = self.get_player()
    if not player:is_usable() then
        UIManager:show(InfoMessage:new{
            text = _("No audio backend on this device.\n\n") .. player:unavailable_reason(),
        })
        return
    end

    local state = self.library:episode(episode)
    local downloaded = state.path and Fetch.file_size(state.path) > 0

    -- Streaming is the fallback, not the default: downloading once and playing
    -- with the radio off is the whole reason to use a podcast client on an
    -- e-reader rather than a phone.
    local source = downloaded and state.path or episode.url
    if not downloaded then
        if not NetworkMgr:isConnected() then
            show_error(_("Not downloaded, and no connection to stream it."))
            return
        end
    end

    local ok, err = player:play{
        url = source,
        title = episode.title,
        kind = "file",
    }
    if not ok then
        show_error(_("Could not play this episode.\n\n") .. tostring(err))
        return
    end

    local start_at = resume and self.library:position(episode) or 0
    if start_at > 5 and player.backend.seek_to then
        -- Seeking before the backend has opened the file is dropped, so wait
        -- for it to report that it is actually playing.
        local attempts = 0
        local function seek_when_ready()
            attempts = attempts + 1
            if player:tick() == "playing" then
                player.backend:seek_to(start_at)
            elseif attempts < 15 then
                UIManager:scheduleIn(1, seek_when_ready)
            else
                logger.dbg("Podcasts: gave up waiting to seek to", start_at)
            end
        end
        UIManager:scheduleIn(1, seek_when_ready)
    end

    if self.on_play then self.on_play(episode) end

    NowPlaying.new{
        player = player,
        library = self.library,
        episode = episode,
    }:show()
end

function Episodes:_show_actions(episode, feed)
    local downloaded = self.library:is_downloaded(episode)
    local position = self.library:position(episode)
    local played = self.library:is_played(episode)

    local dialog
    local function close() UIManager:close(dialog) end

    local buttons = {
        {
            {
                text = (position > 0)
                    and (_("Resume at ") .. (DateTime.format_duration(position) or "0:00"))
                    or _("Play"),
                callback = function()
                    close()
                    self:_play(episode, position > 0)
                end,
            },
        },
        {
            {
                text = downloaded and _("Delete download") or _("Download"),
                callback = function()
                    close()
                    if downloaded then
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete the downloaded audio for this episode?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                self.library:forget_download(episode)
                                self.library:save()
                                self:_refresh_list(feed, episode.guid)
                            end,
                        })
                    else
                        self:_download(episode, feed)
                    end
                end,
            },
        },
        {
            {
                text = played and _("Mark unplayed") or _("Mark played"),
                callback = function()
                    close()
                    self.library:set_played(episode, not played)
                    self.library:save()
                    self:_refresh_list(feed, episode.guid)
                end,
            },
        },
    }

    if position > 0 then
        table.insert(buttons, 1, {
            {
                text = _("Play from the start"),
                callback = function()
                    close()
                    self:_play(episode, false)
                end,
            },
        })
    end

    if episode.description then
        table.insert(buttons, {
            {
                text = _("Show notes"),
                callback = function()
                    close()
                    UIManager:show(InfoMessage:new{ text = episode.description })
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = episode.title .. "\n" .. self:_describe(episode),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Episodes
