local FeedCache = require("net.feedcache")
local Fetch = require("net.fetch")

local TEMP_ROOT = (os.getenv("TMPDIR") or "/tmp") .. "/kopod-cache-spec-" .. tostring(os.time())
local counter = 0

local URL = "https://x.org/feed"
local FEED_V1 = "<rss><channel><title>v1</title></channel></rss>"
local FEED_V2 = "<rss><channel><title>v2</title></channel></rss>"

--- A clock the test moves by hand.
local function clock(start)
    local now = start or 1000000
    return function() return now end, function(seconds) now = now + seconds end
end

--- A fetch that answers from a queue of { body, err, code, info } and records
-- the opts of every request.
local function fake_fetch(responses)
    local fetch = { requests = {} }
    function fetch.get(_self, url, opts)
        fetch.requests[#fetch.requests + 1] = { url = url, opts = opts }
        local response = table.remove(responses, 1)
        assert(response, "unexpected request to " .. url)
        local info = response.info or {}
        info.url = info.url or url
        return response.body, response.err, response.code, info
    end
    return fetch
end

local function fresh_cache(now)
    counter = counter + 1
    local dir = TEMP_ROOT .. "/" .. counter
    os.execute("mkdir -p '" .. dir .. "'")
    return FeedCache.new{ dir = dir, now = now }, dir
end

local function ok(body, info) return { body = body, code = 200, info = info } end
local function not_modified(info)
    return { err = Fetch.NOT_MODIFIED, code = 304, info = info or {} }
end

describe("FeedCache", function()
    it("serves a fresh copy without a request", function()
        local now, advance = clock()
        local cache, dir = fresh_cache(now)
        local fetch = fake_fetch({ ok(FEED_V1, { etag = '"v1"', max_age = 600 }) })
        assert_.equal(FEED_V1, (cache:get(fetch, URL)))

        advance(599)
        -- A new instance, as the next subprocess would make: the index is on disk.
        local reloaded = FeedCache.new{ dir = dir, now = now }
        assert_.truthy(reloaded:is_fresh(URL))
        local body, err, code, info = reloaded:get(fetch, URL)
        assert_.equal(FEED_V1, body)
        assert_.nil_(err)
        assert_.nil_(code)
        assert_.equal("fresh", info.from_cache)
        assert_.len(1, fetch.requests)
    end)

    it("revalidates once max-age has passed and reuses the body on a 304", function()
        local now, advance = clock()
        local cache = fresh_cache(now)
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"', last_modified = "Mon, 14 Jan 2026 00:00:00 GMT",
                max_age = 60 }),
            not_modified({ max_age = 120 }),
        })
        cache:get(fetch, URL)
        advance(61)
        assert_.falsy(cache:is_fresh(URL))

        local body, err, code, info = cache:get(fetch, URL)
        assert_.equal(FEED_V1, body)
        assert_.nil_(err)
        assert_.equal(304, code)
        assert_.equal("revalidated", info.from_cache)
        assert_.equal('"v1"', fetch.requests[2].opts.etag)
        assert_.equal("Mon, 14 Jan 2026 00:00:00 GMT", fetch.requests[2].opts.last_modified)
        -- The 304 restarted the clock with its own max-age.
        advance(119)
        assert_.truthy(cache:is_fresh(URL))
    end)

    it("replaces the body and validators on a 200", function()
        local now, advance = clock()
        local cache, dir = fresh_cache(now)
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"' }),
            ok(FEED_V2, { etag = '"v2"' }),
            not_modified(),
        })
        cache:get(fetch, URL)
        advance(1)
        assert_.equal(FEED_V2, (cache:get(fetch, URL)))
        assert_.equal('"v1"', fetch.requests[2].opts.etag)

        local reloaded = FeedCache.new{ dir = dir, now = now }
        local body = reloaded:get(fetch, URL)
        assert_.equal(FEED_V2, body)
        assert_.equal('"v2"', fetch.requests[3].opts.etag)
    end)

    it("treats a corrupt index as an empty cache", function()
        local now = clock()
        local _, dir = fresh_cache(now)
        local handle = io.open(dir .. "/index.lua", "w")
        handle:write("return { version = 1, feeds = { [\"" .. URL .. "\"] = { file = ")
        handle:close()

        local cache = FeedCache.new{ dir = dir, now = now }
        local fetch = fake_fetch({ ok(FEED_V1, { etag = '"v1"' }) })
        assert_.equal(FEED_V1, (cache:get(fetch, URL)))
        assert_.nil_(fetch.requests[1].opts.etag)
        -- And it recovers: the index is rewritten whole.
        assert_.truthy(FeedCache.new{ dir = dir, now = now }.feeds[URL])
    end)

    it("ignores index entries of the wrong shape", function()
        local now = clock()
        local _, dir = fresh_cache(now)
        local handle = io.open(dir .. "/index.lua", "w")
        handle:write('return { version = 1, feeds = { ["' .. URL ..
            '"] = { file = "../../etc/passwd", size = 1, fetched_at = 0 } } }')
        handle:close()
        assert_.nil_(FeedCache.new{ dir = dir, now = now }.feeds[URL])
    end)

    it("does not send validators when the body file is missing or truncated", function()
        local now, advance = clock()
        local cache, dir = fresh_cache(now)
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"', max_age = 600 }),
            ok(FEED_V2, { etag = '"v2"' }),
        })
        cache:get(fetch, URL)
        local handle = io.open(dir .. "/" .. cache.feeds[URL].file, "w")
        handle:write("<rss>")
        handle:close()

        local reloaded = FeedCache.new{ dir = dir, now = now }
        assert_.falsy(reloaded:is_fresh(URL))
        advance(1)
        assert_.equal(FEED_V2, (reloaded:get(fetch, URL)))
        assert_.nil_(fetch.requests[2].opts.etag)
    end)

    it("keeps nothing when the response has no cache headers", function()
        local now = clock()
        local cache, dir = fresh_cache(now)
        local fetch = fake_fetch({ ok(FEED_V1, {}), ok(FEED_V2, {}) })
        assert_.equal(FEED_V1, (cache:get(fetch, URL)))
        assert_.nil_(cache.feeds[URL])
        assert_.equal(FEED_V2, (cache:get(fetch, URL)))
        assert_.nil_(fetch.requests[2].opts.etag)
        assert_.nil_(fetch.requests[2].opts.last_modified)
        assert_.nil_(FeedCache.new{ dir = dir, now = now }.feeds[URL])
    end)

    it("keeps nothing for no-store, and forgets what it had", function()
        local now = clock()
        local cache = fresh_cache(now)
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"' }),
            ok(FEED_V2, { etag = '"v2"', no_store = true }),
        })
        cache:get(fetch, URL)
        assert_.truthy(cache.feeds[URL])
        cache:get(fetch, URL)
        assert_.nil_(cache.feeds[URL])
    end)

    it("caps a very long max-age at a day", function()
        local now, advance = clock()
        local cache = fresh_cache(now)
        cache:get(fake_fetch({ ok(FEED_V1, { max_age = 31536000 }) }), URL)
        advance(FeedCache.MAX_FRESH_SECONDS - 1)
        assert_.truthy(cache:is_fresh(URL))
        advance(1)
        assert_.falsy(cache:is_fresh(URL))
    end)

    it("is stale when the clock has gone backwards", function()
        local now, advance = clock()
        local cache = fresh_cache(now)
        cache:get(fake_fetch({ ok(FEED_V1, { max_age = 600 }) }), URL)
        advance(-3600)
        assert_.falsy(cache:is_fresh(URL))
    end)

    it("passes errors through and keeps the old entry", function()
        local now, advance = clock()
        local cache = fresh_cache(now)
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"' }),
            { err = "HTTP 500", code = 500 },
        })
        cache:get(fetch, URL)
        advance(1)
        local body, err = cache:get(fetch, URL)
        assert_.nil_(body)
        assert_.equal("HTTP 500", err)
        assert_.truthy(cache.feeds[URL])
    end)

    it("moves the entry with a permanent redirect", function()
        local now = clock()
        local cache = fresh_cache(now)
        local new_url = "https://y.org/feed"
        local fetch = fake_fetch({
            ok(FEED_V1, { etag = '"v1"', url = new_url, moved_to = new_url }),
        })
        cache:get(fetch, URL)
        assert_.nil_(cache.feeds[URL])
        assert_.truthy(cache.feeds[new_url])
        assert_.equal(new_url, cache.feeds[new_url].final_url)
    end)

    it("prunes feeds that are no longer subscribed to, files included", function()
        local now = clock()
        local cache, dir = fresh_cache(now)
        local other = "https://z.org/feed"
        cache:get(fake_fetch({ ok(FEED_V1, { etag = '"a"' }) }), URL)
        cache:get(fake_fetch({ ok(FEED_V2, { etag = '"b"' }) }), other)
        local dropped_file = dir .. "/" .. cache.feeds[other].file

        assert_.truthy(cache:prune({ URL }))
        assert_.truthy(cache.feeds[URL])
        assert_.nil_(cache.feeds[other])
        assert_.nil_(io.open(dropped_file, "rb"))
        assert_.nil_(FeedCache.new{ dir = dir, now = now }.feeds[other])
        assert_.falsy(cache:prune({ URL }))
    end)
end)
