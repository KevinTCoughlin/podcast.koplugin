local Library = require("library")

local TEMP_ROOT = (os.getenv("TMPDIR") or "/tmp") .. "/kopod-spec-" .. tostring(os.time())
local counter = 0

local function fresh_library()
    counter = counter + 1
    local dir = TEMP_ROOT .. "/" .. counter
    os.execute("mkdir -p '" .. dir .. "'")
    return Library.new{
        path = dir .. "/library.lua",
        download_dir = dir .. "/episodes",
    }, dir
end

local function episode(overrides)
    local base = { guid = "guid-1", url = "http://x/ep1.mp3", duration = 600 }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

describe("Library.serialize", function()
    it("round-trips through load()", function()
        local library, dir = fresh_library()
        library:subscribe("http://x/feed.xml", { title = "Show \"quoted\"", author = "A" })
        library:set_position(episode(), 42)
        assert_.truthy(library:save())

        local reloaded = Library.new{ path = dir .. "/library.lua" }
        assert_.len(1, reloaded:subscriptions())
        assert_.equal('Show "quoted"', reloaded:subscriptions()[1].title)
        assert_.equal(42, reloaded:position(episode()))
    end)

    it("emits a stable, sorted file so writes are diffable", function()
        local text = Library.serialize{ b = 1, a = 2, list = { "x", "y" } }
        assert_.truthy(text:find('%["a"%]') < text:find('%["b"%]'))
        assert_.contains(text, '"x"')
    end)

    it("starts empty when there is no file yet", function()
        local library = Library.new{ path = TEMP_ROOT .. "/nonexistent/library.lua" }
        assert_.len(0, library:subscriptions())
    end)
end)

describe("Library subscriptions", function()
    it("adds once and reports whether it was new", function()
        local library = fresh_library()
        local _, first = library:subscribe("http://x/feed.xml", { title = "Show" })
        local _, second = library:subscribe("http://x/feed.xml", { title = "Show Renamed" })
        assert_.truthy(first)
        assert_.falsy(second)
        assert_.len(1, library:subscriptions())
        assert_.equal("Show Renamed", library:subscriptions()[1].title)
    end)

    it("removes by URL", function()
        local library = fresh_library()
        library:subscribe("http://x/feed.xml", { title = "Show" })
        assert_.truthy(library:unsubscribe("http://x/feed.xml"))
        assert_.falsy(library:unsubscribe("http://x/feed.xml"))
        assert_.len(0, library:subscriptions())
    end)

    it("records the episode count only from a complete parse", function()
        local library = fresh_library()
        library:subscribe("http://x/feed.xml", { title = "Show" })
        local capped = { channel = { title = "Show" }, episodes = { {}, {} } }
        library:record_refresh("http://x/feed.xml", capped, false)
        assert_.equal(0, library:subscriptions()[1].episode_count)
        library:record_refresh("http://x/feed.xml", capped, true)
        assert_.equal(2, library:subscriptions()[1].episode_count)
    end)
end)

describe("Library:episode_path", function()
    it("derives a stable name from the guid", function()
        local library = fresh_library()
        local first = library:episode_path(episode())
        assert_.equal(first, library:episode_path(episode()))
        assert_.contains(first, "guid-1.mp3")
    end)

    it("sanitises a guid that would escape the download directory", function()
        -- A guid is publisher-supplied text, and this one is a path traversal.
        local path = fresh_library():episode_path(episode{ guid = "../../etc/passwd" })
        assert_.falsy(path:find("%.%./"), "traversal must not survive: " .. path)
    end)

    it("keeps the audio extension, and falls back to mp3", function()
        local library = fresh_library()
        assert_.contains(library:episode_path(episode{ url = "http://x/a.m4a" }), ".m4a")
        assert_.contains(library:episode_path(episode{ url = "http://x/a.mp3?t=1" }), ".mp3")
        assert_.contains(library:episode_path(episode{ url = "http://x/stream" }), ".mp3")
    end)
end)

describe("Library episode state", function()
    it("survives a refresh replacing the episode list", function()
        -- The reason state is keyed by guid and stored apart from the feed.
        local library = fresh_library()
        library:set_position(episode(), 120)
        library:record_refresh("http://x/feed.xml",
            { channel = {}, episodes = {} }, true)
        assert_.equal(120, library:position(episode()))
    end)

    it("marks an episode played within a minute of the end", function()
        local library = fresh_library()
        library:set_position(episode{ duration = 600 }, 300)
        assert_.falsy(library:is_played(episode()))
        library:set_position(episode{ duration = 600 }, 545)
        assert_.truthy(library:is_played(episode()))
    end)

    it("does not mark played when the duration is unknown", function()
        local library = fresh_library()
        -- Built explicitly: `episode{ duration = nil }` cannot remove the
        -- default, since a nil value in a table literal is simply absent.
        library:set_position({ guid = "guid-1", url = "http://x/ep1.mp3" }, 99999)
        assert_.falsy(library:is_played(episode()))
    end)

    it("clears the position when explicitly marked played", function()
        local library = fresh_library()
        library:set_position(episode(), 120)
        library:set_played(episode(), true)
        assert_.equal(0, library:position(episode()))
        assert_.truthy(library:is_played(episode()))
        library:set_played(episode(), false)
        assert_.falsy(library:is_played(episode()))
    end)

    it("never returns a negative position", function()
        local library = fresh_library()
        library:set_position(episode(), -50)
        assert_.equal(0, library:position(episode()))
    end)

    it("reports a download only while the file is actually there", function()
        local library, dir = fresh_library()
        local path = dir .. "/episodes/ep.mp3"
        os.execute("mkdir -p '" .. dir .. "/episodes'")
        assert_.falsy(library:is_downloaded(episode()))

        local handle = io.open(path, "w")
        handle:write("audio")
        handle:close()
        library:mark_downloaded(episode(), path, 5)
        assert_.truthy(library:is_downloaded(episode()))

        -- A file deleted behind our back, e.g. by the user tidying up storage.
        os.remove(path)
        assert_.falsy(library:is_downloaded(episode()))
    end)

    it("forgetting a download removes the file and the state", function()
        local library, dir = fresh_library()
        os.execute("mkdir -p '" .. dir .. "/episodes'")
        local path = dir .. "/episodes/ep.mp3"
        local handle = io.open(path, "w"); handle:write("x"); handle:close()
        library:mark_downloaded(episode(), path, 1)
        library:forget_download(episode())
        assert_.falsy(library:is_downloaded(episode()))
        assert_.nil_(io.open(path, "r"))
    end)
end)

describe("Library episode state across feeds", function()
    local A, B = "https://a.org/feed", "https://b.org/feed"

    it("keeps the same guid in two feeds apart", function()
        local library = fresh_library()
        library:set_position(episode{ feed_url = A }, 100)
        library:set_position(episode{ feed_url = B }, 200)
        assert_.equal(100, library:position(episode{ feed_url = A }))
        assert_.equal(200, library:position(episode{ feed_url = B }))
    end)

    it("migrates a legacy guid-only entry to the first feed that asks", function()
        local library, dir = fresh_library()
        local handle = io.open(dir .. "/library.lua", "w")
        handle:write('return { subscriptions = {}, episode_state = { ["guid-1"] = { position = 42 } } }')
        handle:close()
        library = Library.new{ path = dir .. "/library.lua" }

        assert_.equal(42, library:position(episode{ feed_url = A }))
        -- Claimed: it now belongs to A, and B does not inherit it.
        assert_.equal(0, library:position(episode{ feed_url = B }))
        assert_.nil_(library.data.episode_state["guid-1"])

        assert_.truthy(library:save())
        local reloaded = Library.new{ path = dir .. "/library.lua" }
        assert_.equal(42, reloaded:position(episode{ feed_url = A }))
        local text = io.open(dir .. "/library.lua"):read("*a")
        assert_.falsy(text:find("episode_state", 1, true), "empty legacy table is dropped")
    end)

    it("still serves an episode with no feed from the legacy table", function()
        local library = fresh_library()
        library:set_position(episode(), 30)
        assert_.equal(30, library.data.episode_state["guid-1"].position)
        assert_.equal(30, library:position(episode()))
    end)

    it("gives same-guid episodes of different feeds different files", function()
        local library = fresh_library()
        local a = library:episode_path(episode{ feed_url = A })
        local b = library:episode_path(episode{ feed_url = B })
        assert_.truthy(a ~= b)
        assert_.contains(a, "guid-1.mp3")
    end)
end)

describe("Library redirects and conditional refresh", function()
    local OLD, NEW = "http://x.org/feed", "https://x.org/feed"

    it("renames a subscription and carries its episode state", function()
        local library = fresh_library()
        library:subscribe(OLD, { title = "Show" })
        library:apply_refresh(OLD, { validators = true, etag = '"1"' })
        library:set_position(episode{ feed_url = OLD }, 77)

        local subscription = library:rename_feed(OLD, NEW)
        assert_.equal(NEW, subscription.url)
        assert_.nil_(library:find(OLD))
        assert_.nil_(subscription.etag, "validators belong to the old URL")
        assert_.equal(77, library:position(episode{ feed_url = NEW }))
    end)

    it("merges into an existing subscription at the new URL", function()
        local library = fresh_library()
        library:subscribe(OLD, { title = "Old" })
        library:subscribe(NEW, { title = "New" })
        library:set_position(episode{ feed_url = OLD, guid = "only-old" }, 5)
        local subscription = library:rename_feed(OLD, NEW)
        assert_.len(1, library:subscriptions())
        assert_.equal("New", subscription.title)
        assert_.equal(5, library:position(episode{ feed_url = NEW, guid = "only-old" }))
    end)

    it("follows moved_to from a refresh", function()
        local library = fresh_library()
        library:subscribe(OLD, { title = "Show" })
        library:apply_refresh(OLD, { moved_to = NEW, count = 3, validators = true, etag = '"n"' })
        local subscription = library:find(NEW)
        assert_.equal(3, subscription.episode_count)
        assert_.equal('"n"', subscription.etag)
        assert_.deep_equal({ etag = '"n"' }, library:validators(NEW))
    end)

    it("stores validators as a pair, and keeps the count on a 304", function()
        local library = fresh_library()
        library:subscribe(OLD, { title = "Show" })
        library:apply_refresh(OLD, { count = 9, validators = true,
            etag = '"1"', last_modified = "Tue, 15 Jan 2026 04:47:54 GMT" })
        library:apply_refresh(OLD, { not_modified = true, validators = true, etag = '"1"' })
        local subscription = library:find(OLD)
        assert_.equal(9, subscription.episode_count)
        assert_.nil_(subscription.last_modified, "server stopped sending it")
        assert_.truthy(subscription.last_refreshed)
    end)

    it("leaves validators alone on a refresh that does not set them", function()
        local library = fresh_library()
        library:subscribe(OLD, { title = "Show" })
        library:apply_refresh(OLD, { validators = true, etag = '"1"' })
        library:record_refresh(OLD, { channel = {}, episodes = {} }, false)
        assert_.equal('"1"', library:find(OLD).etag)
    end)
end)
