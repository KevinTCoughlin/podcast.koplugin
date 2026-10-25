--[[--
The subscription list: what you are subscribed to, and adding or removing one.

Reading the list needs no network at all -- it comes from the library file --
which is the point. An e-reader is usually offline, and being unable to see what
you subscribe to because the Wi-Fi is off would be absurd. Only opening a show
or refreshing reaches for the network, and `NetworkMgr:runWhenOnline` is where
the user gets asked about it.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")

local Episodes = require("ui/episodes")
local Fetch = require("net.fetch")
local Parser = require("feed.parser")

local Subscriptions = {}
Subscriptions.__index = Subscriptions

function Subscriptions.new(opts)
    return setmetatable({
        library = opts.library,
        get_player = opts.get_player,
        on_play = opts.on_play,
        user_agent = opts.user_agent,
        fetch = Fetch.new(nil, { user_agent = opts.user_agent }),
    }, Subscriptions)
end

local function show_error(message)
    UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 5 })
end

function Subscriptions:_close_menu()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

local function describe(subscription)
    local parts = {}
    if subscription.author then parts[#parts + 1] = subscription.author end
    if (subscription.episode_count or 0) > 0 then
        parts[#parts + 1] = string.format(_("%d episodes"), subscription.episode_count)
    end
    if subscription.last_refreshed then
        parts[#parts + 1] = _("refreshed ") .. os.date("!%Y-%m-%d", subscription.last_refreshed)
    else
        parts[#parts + 1] = _("never refreshed")
    end
    return table.concat(parts, "  \194\183  ")
end

function Subscriptions:show()
    local subscriptions = self.library:subscriptions()
    if #subscriptions == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No podcasts yet.\n\nUse \"Add a podcast\" and paste a feed URL."),
        })
        return
    end

    local items = {}
    for _index, subscription in ipairs(subscriptions) do
        items[#items + 1] = {
            text = subscription.title,
            help_text = describe(subscription),
            subscription = subscription,
        }
    end

    self:_close_menu()
    self.menu = Menu:new{
        title = _("Podcasts"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            self:_open(item.subscription)
            return true
        end,
        onMenuHold = function(_menu, item)
            self:_show_actions(item.subscription)
            return true
        end,
        close_callback = function() self.menu = nil end,
    }
    UIManager:show(self.menu)
end

function Subscriptions:_open(subscription)
    Episodes.new{
        library = self.library,
        subscription = subscription,
        get_player = self.get_player,
        on_play = self.on_play,
        user_agent = self.user_agent,
    }:show()
end

function Subscriptions:_show_actions(subscription)
    local dialog
    dialog = ButtonDialog:new{
        title = subscription.title .. "\n" .. subscription.url,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Open"),
                    callback = function()
                        UIManager:close(dialog)
                        self:_open(subscription)
                    end,
                },
            },
            {
                {
                    text = _("Unsubscribe"),
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = _("Unsubscribe from:\n\n") .. subscription.title ..
                                _("\n\nDownloaded audio files are left on the device."),
                            ok_text = _("Unsubscribe"),
                            ok_callback = function()
                                self.library:unsubscribe(subscription.url)
                                self.library:save()
                                self:_close_menu()
                                self:show()
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--- Fetches a feed just far enough to learn its title, then subscribes.
-- Capped at one episode on purpose: this is a name lookup, not a sync, and
-- parsing a 20 MB back catalogue to find out what a show is called is waste.
function Subscriptions:add()
    local dialog
    dialog = InputDialog:new{
        title = _("Add a podcast"),
        input_hint = _("Feed URL"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    UIManager:close(dialog)
                    if not url or url == "" then return end
                    url = url:gsub("^%s+", ""):gsub("%s+$", "")
                    -- A bare host is the commonest paste mistake, and the
                    -- fetch failure it produces is not self-explanatory.
                    if not url:match("^https?://") then
                        show_error(_("A feed URL has to start with http:// or https://"))
                        return
                    end
                    self:_subscribe(url)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Subscriptions:_subscribe(url)
    local fetch_kind = self.fetch.kind
    local user_agent = self.user_agent

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                local ChildFetch = require("net.fetch")
                local ChildParser = require("feed.parser")
                local fetch = ChildFetch.new(fetch_kind, { user_agent = user_agent })
                local body, err, _code, info = fetch:get(url, { timeout = 45 })
                if not body then return { error = tostring(err) } end
                local feed, parse_err = ChildParser.parse(body, { max_episodes = 1, base_url = info.url })
                if not feed then
                    -- A show's web page rather than its feed: follow the feed
                    -- the page advertises, if it advertises one.
                    local discovered = ChildParser.discover(body, info.url)
                    if not discovered then return { error = tostring(parse_err) } end
                    body, err, _code, info = fetch:get(discovered, { timeout = 45 })
                    if not body then return { error = tostring(err) } end
                    feed, parse_err = ChildParser.parse(body, { max_episodes = 1, base_url = info.url })
                    if not feed then return { error = tostring(parse_err) } end
                    return { channel = feed.channel, episodes = #feed.episodes,
                        url = info.moved_to or discovered }
                end
                return { channel = feed.channel, episodes = #feed.episodes,
                    url = info.moved_to or url }
            end, _("Checking the feed…\n\nTap to cancel."))

            if not completed then return end
            if not result or result.error then
                show_error(_("Not a podcast feed.\n\n") ..
                    tostring(result and result.error or "unknown error"))
                return
            end
            if result.episodes == 0 then
                show_error(_("That feed has no audio episodes.\n\n") ..
                    _("It may be an ordinary RSS feed rather than a podcast."))
                return
            end

            local subscription, was_new = self.library:subscribe(result.url or url, result.channel)
            self.library:save()
            UIManager:show(InfoMessage:new{
                text = (was_new and _("Subscribed to ") or _("Already subscribed to ")) ..
                    subscription.title,
                timeout = 3,
            })
            self:_close_menu()
            self:show()
        end)
    end)
end

--- Refreshes every subscription's episode count and title in one pass.
function Subscriptions:refresh_all()
    local subscriptions = self.library:subscriptions()
    if #subscriptions == 0 then
        show_error(_("Nothing to refresh."))
        return
    end

    local urls, validators = {}, {}
    for _index, subscription in ipairs(subscriptions) do
        urls[#urls + 1] = subscription.url
        validators[subscription.url] = self.library:validators(subscription.url)
    end
    local fetch_kind = self.fetch.kind
    local user_agent = self.user_agent

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local completed, results = Trapper:dismissableRunInSubprocess(function()
                local ChildFetch = require("net.fetch")
                local ChildParser = require("feed.parser")
                local fetch = ChildFetch.new(fetch_kind, { user_agent = user_agent })
                local out = {}
                for _index, url in ipairs(urls) do
                    -- Conditional: an unchanged feed is a 304 with no body,
                    -- which is most feeds on most refreshes.
                    local known = validators[url] or {}
                    local body, err, _code, info = fetch:get(url, {
                        timeout = 45, etag = known.etag, last_modified = known.last_modified,
                    })
                    if err == ChildFetch.NOT_MODIFIED then
                        out[url] = { not_modified = true, moved_to = info and info.moved_to,
                            validators = true, etag = info and info.etag or known.etag,
                            last_modified = info and info.last_modified or known.last_modified }
                    else
                        local feed = body and ChildParser.parse(body, { base_url = info.url })
                        -- A feed that fails is skipped, not fatal: one dead show
                        -- must not block refreshing the rest.
                        if feed then
                            out[url] = {
                                title = feed.channel.title,
                                author = feed.channel.author,
                                image = feed.channel.image,
                                count = #feed.episodes,
                                moved_to = info.moved_to,
                                validators = true,
                                etag = info.etag,
                                last_modified = info.last_modified,
                            }
                        end
                    end
                end
                return out
            end, _("Refreshing podcasts…\n\nTap to cancel."))

            if not completed then return end

            local refreshed, failed = 0, 0
            -- A copy: apply_refresh can rename or merge subscriptions.
            local snapshot = {}
            for index, subscription in ipairs(subscriptions) do snapshot[index] = subscription end
            for _index, subscription in ipairs(snapshot) do
                local result = results and results[subscription.url]
                if result then
                    self.library:apply_refresh(subscription.url, result)
                    refreshed = refreshed + 1
                else
                    failed = failed + 1
                end
            end
            self.library:save()

            local message = string.format(_("Refreshed %d podcasts."), refreshed)
            if failed > 0 then
                message = message .. string.format(_("\n%d could not be reached."), failed)
            end
            UIManager:show(InfoMessage:new{ text = message, timeout = 4 })
            self:_close_menu()
            self:show()
        end)
    end)
end

return Subscriptions
