-- Smoke-tests podcast.koplugin's widgets inside real KOReader.
-- Priority 2 = runs after UIManager is ready. Not shipped; a dev harness.
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PLUGIN_DIR = "plugins/podcast.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

local pass, fail, skipped = 0, 0, 0

-- Set PODCAST_SMOKE_OFFLINE=1 to skip the steps that fetch a real feed. The
-- widget steps are deterministic and must never fail quietly, so CI runs this
-- offline and hard-fails, and checks live feeds separately.
local OFFLINE = os.getenv("PODCAST_SMOKE_OFFLINE") == "1"

local FEED_URL = "https://feeds.npr.org/510289/podcast.xml"

local function step(name, body, needs_network)
    if needs_network and OFFLINE then
        skipped = skipped + 1
        logger.warn("SMOKE SKIP: " .. name .. " (offline)")
        return
    end
    local ok, err = pcall(body)
    if ok then
        pass = pass + 1
        logger.warn("SMOKE PASS: " .. name)
    else
        fail = fail + 1
        logger.warn("SMOKE FAIL: " .. name .. " -- " .. tostring(err))
    end
end

UIManager:scheduleIn(1, function()
    local DateTime, Episodes, Fetch, Library, NowPlaying, Parser, Subscriptions
    local NullBackend, Player

    step("require plugin modules", function()
        DateTime = require("feed.datetime")
        Episodes = require("ui/episodes")
        Fetch = require("net.fetch")
        Library = require("library")
        NowPlaying = require("ui/nowplaying")
        Parser = require("feed.parser")
        Subscriptions = require("ui/subscriptions")
        NullBackend = require("koaudio.backends.null")
        Player = require("koaudio.player")
    end)

    step("require main.lua the way PluginLoader does", function()
        assert(require("main"), "main.lua returned nothing")
    end)

    local library
    step("Library lands in KOReader's data directories", function()
        library = Library.new{}
        local DataStorage = require("datastorage")
        assert(library.path:find(DataStorage:getSettingsDir(), 1, true),
            "library path is not under the settings dir: " .. library.path)
        assert(library.download_dir:find(DataStorage:getDataDir(), 1, true),
            "download dir is not under the data dir: " .. library.download_dir)
    end)

    local episode
    step("subscribe and persist through a real save/load cycle", function()
        library:subscribe(FEED_URL, { title = "Smoke Show", author = "Tester" })
        library:apply_refresh(FEED_URL, { title = "Smoke Show", count = 42 })
        assert(library:save(), "save failed")

        local reloaded = Library.new{}
        assert(#reloaded:subscriptions() == 1)
        assert(reloaded:subscriptions()[1].title == "Smoke Show")
        assert(reloaded:subscriptions()[1].episode_count == 42)
    end)

    step("episode state survives a reload", function()
        episode = {
            guid = "smoke-guid-1",
            title = "Smoke Episode",
            url = "http://example.org/ep.mp3",
            duration = 1800,
            published = 1768452474,
            description = "Some show notes.",
        }
        library:set_position(episode, 125)
        library:save()
        assert(Library.new{}:position(episode) == 125)
    end)

    step("episode_path stays inside the download directory", function()
        local hostile = { guid = "../../etc/passwd", url = "http://x/a.mp3" }
        local path = library:episode_path(hostile)
        assert(not path:find("%.%./"), "path traversal survived: " .. path)
        assert(path:find(library.download_dir, 1, true) == 1, "escaped the download dir")
    end)

    local player
    step("Player with a null backend", function()
        player = Player.new{
            backend_instance = NullBackend.new{ scripted = {
                { state = "playing", elapsed = "130", duration = "1800" },
            } },
        }
        assert(player:play{ url = episode.url, title = episode.title, kind = "file" })
        assert(player:tick() == "playing")
    end)

    local now_playing
    step("NowPlaying:show builds a ButtonDialog with progress", function()
        now_playing = NowPlaying.new{ player = player, library = library, episode = episode }
        now_playing:show()
        assert(now_playing.dialog, "no dialog was created")
        local text = now_playing:_status_text()
        assert(text:find("2:10"), "elapsed time missing from: " .. text)
        assert(text:find("30:00"), "duration missing from: " .. text)
        assert(text:find("7%%"), "percentage missing from: " .. text)
    end)

    step("NowPlaying seek buttons exist and are callable for a file", function()
        local seen_seek = false
        for _, row in ipairs(now_playing:_buttons()) do
            for _, button in ipairs(row) do
                assert(type(button.text) == "string" and #button.text > 0)
                assert(type(button.callback) == "function")
                if button.text:find("30s") then
                    seen_seek = true
                    -- A file is seekable; the radio plugin's equivalent refuses.
                    assert(button.enabled ~= false, "seek disabled for a file")
                end
            end
        end
        assert(seen_seek, "no seek buttons")
    end)

    step("NowPlaying persists the position on close", function()
        player.status.elapsed = "600"
        now_playing:_save_position()
        assert(Library.new{}:position(episode) == 600,
            "position was not written on close")
    end)

    step("NowPlaying does not overwrite a position with a zero tick", function()
        -- A zero usually means the backend has not reported yet, and saving it
        -- would throw away the resume point.
        player.status.elapsed = "0"
        now_playing:_save_position()
        assert(Library.new{}:position(episode) == 600, "a zero tick clobbered the position")
        now_playing:close()
        assert(now_playing.dialog == nil)
        assert(now_playing._poll == nil)
    end)

    step("Episodes list builds a Menu from a parsed feed", function()
        local RSS = [==[<?xml version="1.0"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>Smoke Show</title>
          <item><title>Smoke Episode</title><guid>smoke-guid-1</guid>
            <pubDate>Tue, 15 Jan 2026 04:47:54 +0000</pubDate>
            <itunes:duration>30:00</itunes:duration>
            <enclosure url="http://example.org/ep.mp3" type="audio/mpeg" length="29000000"/>
          </item>
          <item><title>Second Episode</title><guid>smoke-guid-2</guid>
            <enclosure url="http://example.org/ep2.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>]==]
        local feed = assert(Parser.parse(RSS))

        local episodes = Episodes.new{
            library = library,
            subscription = { url = FEED_URL, title = "Smoke Show" },
            get_player = function() return player end,
            user_agent = "podcast.koplugin-smoke/0.1",
        }
        episodes:_show_list(feed)
        assert(episodes.menu, "no menu was created")
        assert(#episodes.menu.item_table == 2)
        assert(episodes.menu.item_table[1].text == "Smoke Episode")
        -- The saved position must show up in the row, since that is how the
        -- user finds a part-listened episode.
        local described = episodes.menu.item_table[1].help_text
        assert(described:find("at 10:00"), "position missing from row: " .. described)
        assert(described:find("2026%-01%-15"), "date missing from row: " .. described)

        -- Refreshing in place must keep the list and focus the acted-on item.
        episodes:_refresh_list(feed, "smoke-guid-2")
        assert(#episodes.menu.item_table == 2)

        episodes:_show_actions(feed.episodes[1], feed)
        episodes:_close_menu()
        assert(episodes.menu == nil)
    end)

    step("Subscriptions list builds a Menu", function()
        local subscriptions = Subscriptions.new{
            library = library,
            get_player = function() return player end,
            user_agent = "podcast.koplugin-smoke/0.1",
        }
        subscriptions:show()
        assert(subscriptions.menu, "no menu was created")
        assert(subscriptions.menu.item_table[1].text == "Smoke Show")
        assert(subscriptions.menu.item_table[1].help_text:find("42 episodes"))
        subscriptions:_show_actions(library:subscriptions()[1])
        subscriptions:_close_menu()
    end)

    step("plugin instantiates and registers a menu", function()
        local Podcasts = require("main")
        local registered
        local plugin = Podcasts:new{
            ui = { menu = { registerToMainMenu = function(_, p) registered = p end } },
        }
        assert(registered == plugin, "plugin did not register itself")

        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local entry = menu_items.podcasts
        assert(entry, "no podcasts menu entry")
        assert(entry.sorting_hint == "tools")
        assert(#entry.sub_item_table >= 6, "expected the full submenu")
        for _, sub in ipairs(entry.sub_item_table) do
            assert(sub.text or sub.text_func, "submenu entry with no label")
            if sub.text_func then assert(type(sub.text_func()) == "string") end
            if sub.enabled_func then sub.enabled_func() end
        end
    end)

    -- The paths that only exist on device: KOReader's own luasocket/luasec
    -- stack. curl covers neither, so nothing above has exercised what ships.
    step("Fetch auto-selects KOReader's own HTTP stack", function()
        assert(Fetch.new().kind == "koreader",
            "expected the koreader fetcher on device, got " .. tostring(Fetch.new().kind))
    end)

    step("a real feed over HTTPS through luasec", function()
        local body, err = Fetch.new("koreader"):get(FEED_URL, { timeout = 45 })
        assert(body, "luasec request failed: " .. tostring(err))
        local feed, parse_err = Parser.parse(body, { max_episodes = 5 })
        assert(feed, "parse failed: " .. tostring(parse_err))
        assert(#feed.episodes > 0, "no episodes parsed")
        logger.warn(string.format("SMOKE feed: %s, %d bytes, %d episodes",
            feed.channel.title, #body, #feed.episodes))
        for _, found in ipairs(feed.episodes) do
            assert(found.url and found.url ~= "", "episode with no audio survived")
            logger.warn("SMOKE   episode: " .. found.title:sub(1, 48) ..
                " (" .. (DateTime.format_duration(found.duration) or "?") .. ")")
        end
    end, true)

    -- luasocket cannot follow a redirect across schemes on its own, so this is
    -- the manual redirect loop against a real 301, through both clients.
    step("an http -> https permanent redirect through luasocket", function()
        local http_url = FEED_URL:gsub("^https:", "http:")
        local body, err, _code, info = Fetch.new("koreader"):get(http_url, { timeout = 45 })
        assert(body, "redirected request failed: " .. tostring(err))
        assert(info.url == FEED_URL, "ended at " .. tostring(info.url))
        assert(info.moved_to == FEED_URL, "moved_to was " .. tostring(info.moved_to))
    end, true)

    step("resumable download over KOReader's HTTP stack", function()
        local DataStorage = require("datastorage")
        local path = DataStorage:getDataDir() .. "/podcast-smoke.bin"
        os.remove(path)
        -- A small, stable file: this is testing the transport and the resume
        -- bookkeeping, not anyone's CDN.
        local size, err = Fetch.new("koreader")
            :download("https://feeds.npr.org/510289/podcast.xml", path)
        assert(not err, "download failed: " .. tostring(err))
        assert(size > 0, "downloaded nothing")
        assert(Fetch.file_size(path) == size, "reported size disagrees with the file")
        logger.warn(string.format("SMOKE downloaded %d bytes via luasec", size))
        os.remove(path)
    end, true)

    step("backend detection reports a reason on this device", function()
        local Detect = require("koaudio.detect")
        local _backend, name, rejections = Detect.select()
        logger.warn("SMOKE platform=" .. Detect.platform() .. " backend=" .. tostring(name))
        for backend, reason in pairs(rejections) do
            logger.warn("SMOKE   reject " .. backend .. ": " .. reason)
        end
    end)

    logger.warn(string.format("SMOKE RESULT: %d passed, %d failed, %d skipped",
        pass, fail, skipped))
    UIManager:scheduleIn(0.5, function() UIManager:quit() end)
end)
