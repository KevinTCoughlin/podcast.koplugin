--[[--
The podcast player.

Differs from a radio now-playing screen in the two ways that matter: an episode
has a duration and a position, so it can be seeked and must be resumed; and the
position has to be *persisted*, because the whole point of a podcast client is
that closing it does not lose your place.

Position is written to the library on a timer rather than on every tick. A
LuaSettings flush is a file write, and doing one per second on a device with
slow flash and a finite flash lifetime is antisocial for no benefit.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local DateTime = require("feed.datetime")

local NowPlaying = {}
NowPlaying.__index = NowPlaying

local POLL_INTERVAL = 1
--- How often the position is persisted while playing. Also written on close.
local SAVE_INTERVAL = 15
local SEEK_STEP = 30

function NowPlaying.new(opts)
    return setmetatable({
        player = opts.player,
        library = opts.library,
        episode = opts.episode,
        dialog = nil,
        last_text = nil,
        ticks_since_save = 0,
    }, NowPlaying)
end

function NowPlaying:_status_text()
    local player = self.player
    local lines = { self.episode.title }

    local state = player.state
    if state == "opening" or state == "buffering" then
        lines[#lines + 1] = _("Loading…")
    elseif state == "error" then
        lines[#lines + 1] = _("Error: ") .. tostring(player.status.error or "?")
    else
        local elapsed = tonumber(player.status.elapsed) or 0
        -- The player's own duration beats the feed's: publishers get the feed
        -- value wrong often enough that trusting it misreports the position.
        local duration = tonumber(player.status.duration) or self.episode.duration or 0
        local position = DateTime.format_duration(elapsed) or "0:00"
        if duration > 0 then
            lines[#lines + 1] = string.format("%s / %s",
                position, DateTime.format_duration(duration) or "?")
            lines[#lines + 1] = string.format("%d%%", math.floor(elapsed / duration * 100))
        else
            lines[#lines + 1] = position
        end
        if state == "paused" then lines[#lines + 1] = _("Paused") end
    end
    return table.concat(lines, "\n")
end

function NowPlaying:_seek(seconds)
    local ok, err = self.player:seek(seconds)
    if not ok then
        UIManager:show(InfoMessage:new{ text = tostring(err), timeout = 3 })
        return
    end
    -- Give the backend a moment to move before repainting, otherwise the
    -- screen flashes with the pre-seek position.
    UIManager:scheduleIn(0.3, function()
        self.player:tick()
        self:refresh()
    end)
end

function NowPlaying:_buttons()
    local player = self.player
    return {
        {
            {
                text = string.format(_("− %ds"), SEEK_STEP),
                enabled = player:capabilities().seek,
                callback = function() self:_seek(-SEEK_STEP) end,
            },
            {
                text = (player.state == "paused") and _("Resume") or _("Pause"),
                enabled = player:capabilities().pause and player.state ~= "error",
                callback = function()
                    player:toggle()
                    self:refresh()
                end,
            },
            {
                text = string.format(_("+ %ds"), SEEK_STEP),
                enabled = player:capabilities().seek,
                callback = function() self:_seek(SEEK_STEP) end,
            },
        },
        {
            {
                text = _("Volume −"),
                callback = function()
                    player:set_volume(player.volume - 10)
                    self:refresh()
                end,
            },
            {
                text = _("Volume +"),
                callback = function()
                    player:set_volume(player.volume + 10)
                    self:refresh()
                end,
            },
        },
        {
            {
                text = _("Mark played"),
                callback = function()
                    self.library:set_played(self.episode, true)
                    self.library:save()
                    player:stop()
                    self:close()
                end,
            },
            {
                -- Closing keeps playing and stops the polling; stopping ends it.
                -- Both save the position first.
                text = _("Stop"),
                callback = function()
                    self:_save_position()
                    player:stop()
                    self:close()
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    self:_save_position()
                    self:close()
                end,
            },
        },
    }
end

function NowPlaying:_save_position()
    local elapsed = tonumber(self.player.status.elapsed)
    -- A zero here usually means "the backend has not reported yet" rather than
    -- "the user is at the very start", and saving it would throw away a resume
    -- point the user had before opening this screen.
    if not elapsed or elapsed <= 0 then return end
    self.library:set_position(self.episode, elapsed)
    self.library:save()
end

function NowPlaying:show()
    self.dialog = ButtonDialog:new{
        title = self:_status_text(),
        title_align = "center",
        buttons = self:_buttons(),
    }
    UIManager:show(self.dialog)
    self:_schedule_poll()
    return self
end

function NowPlaying:refresh()
    if not self.dialog then return end
    local text = self:_status_text()
    if text == self.last_text then return end
    self.last_text = text

    UIManager:close(self.dialog)
    self.dialog = ButtonDialog:new{
        title = text,
        title_align = "center",
        buttons = self:_buttons(),
    }
    UIManager:show(self.dialog)
end

function NowPlaying:_schedule_poll()
    self._poll = function()
        if not self.dialog then return end
        local state = self.player:tick()
        self:refresh()

        self.ticks_since_save = self.ticks_since_save + POLL_INTERVAL
        if self.ticks_since_save >= SAVE_INTERVAL then
            self.ticks_since_save = 0
            self:_save_position()
        end

        if state == "error" then
            UIManager:show(InfoMessage:new{
                text = _("Playback stopped: ") .. tostring(self.player.status.error or "?"),
            })
            self:close()
            return
        end
        if state == "stopped" then
            self:close()
            return
        end
        UIManager:scheduleIn(POLL_INTERVAL, self._poll)
    end
    UIManager:scheduleIn(POLL_INTERVAL, self._poll)
end

--- Closes the widget and stops polling. Does *not* stop playback.
function NowPlaying:close()
    if self._poll then
        UIManager:unschedule(self._poll)
        self._poll = nil
    end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

return NowPlaying
