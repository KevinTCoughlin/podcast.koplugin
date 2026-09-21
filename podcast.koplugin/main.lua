--[[--
podcast.koplugin -- podcasts for KOReader.

Menu wiring only; the work lives in ui/ and in the feed and library modules.

The player is shared with the radio plugin through koaudio, which is vendored
here from shoutkit.koplugin. Note the submodule requires below: KOReader's
PluginLoader puts only "<plugin>/?.lua" on package.path and never "?/init.lua"
(frontend/pluginloader.lua), so `require("koaudio")` cannot resolve the
directory from inside a plugin.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Detect = require("koaudio.detect")
local Library = require("library")
local NowPlaying = require("ui/nowplaying")
local Player = require("koaudio.player")
local Subscriptions = require("ui/subscriptions")

local USER_AGENT =
    "podcast.koplugin/0.1.0 (+https://github.com/KevinTCoughlin/podcast.koplugin)"

local Podcasts = WidgetContainer:extend{
    name = "podcasts",
    is_doc_only = false,
}

function Podcasts:init()
    self.library = Library.new{}
    -- Lazily constructed: building a Player probes every backend, and there is
    -- no reason to do that for a user who never opens the menu.
    self.player = nil
    self.playing_episode = nil
    self.ui.menu:registerToMainMenu(self)
end

function Podcasts:_get_player()
    if not self.player then
        self.player = Player.new{ volume = 60 }
    end
    return self.player
end

function Podcasts:_subscriptions()
    return Subscriptions.new{
        library = self.library,
        user_agent = USER_AGENT,
        get_player = function() return self:_get_player() end,
        -- Remembered so "Now playing" can reopen the right episode after the
        -- episode list has been closed.
        on_play = function(episode) self.playing_episode = episode end,
    }
end

function Podcasts:_show_now_playing()
    local player = self:_get_player()
    if player.state == "stopped" or not player.item then
        UIManager:show(InfoMessage:new{ text = _("Nothing is playing."), timeout = 3 })
        return
    end
    -- Reconstruct just enough of an episode for the widget: the guid is what
    -- the position is keyed by, and the player item carries the title.
    NowPlaying.new{
        player = player,
        library = self.library,
        episode = self.playing_episode or {
            guid = player.item.url,
            title = player.item.title or _("Episode"),
            url = player.item.url,
        },
    }:show()
end

function Podcasts:addToMainMenu(menu_items)
    menu_items.podcasts = {
        text = _("Podcasts"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Now playing"),
                enabled_func = function()
                    return self.player ~= nil and self.player.state ~= "stopped"
                end,
                callback = function() self:_show_now_playing() end,
            },
            {
                text = _("Podcasts"),
                separator = true,
                callback = function() self:_subscriptions():show() end,
            },
            {
                text = _("Add a podcast"),
                callback = function() self:_subscriptions():add() end,
            },
            {
                text = _("Refresh all"),
                separator = true,
                callback = function() self:_subscriptions():refresh_all() end,
            },
            {
                text = _("Stop playback"),
                enabled_func = function()
                    return self.player ~= nil and self.player.state ~= "stopped"
                end,
                callback = function()
                    if self.player then self.player:stop() end
                end,
            },
            {
                text_func = function()
                    local _backend, name = Detect.select()
                    return _("Audio backend: ") .. tostring(name or _("none"))
                end,
                keep_menu_open = true,
                callback = function()
                    local _backend, name, rejections = Detect.select()
                    local lines = { _("Platform: ") .. Detect.platform() }
                    lines[#lines + 1] = _("Selected: ") .. tostring(name or _("none"))
                    for backend, reason in pairs(rejections) do
                        lines[#lines + 1] = backend .. ": " .. reason
                    end
                    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                end,
            },
        },
    }
end

--- Playback outlives the reader UI, so a closing document must not orphan the
-- backend process.
function Podcasts:onCloseWidget()
    if self.player then self.player:stop() end
end

return Podcasts
