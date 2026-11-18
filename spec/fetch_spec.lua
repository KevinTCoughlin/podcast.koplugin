local Fetch = require("net.fetch")

--- Installs fake luasocket modules that serve `routes[url]` =
-- { code, headers, body }, and records each request.
local function with_fake_socket(routes, body)
    local requests = {}
    local function request(params)
        requests[#requests + 1] = params
        local route = routes[params.url]
        if not route then return nil, "connection refused" end
        if route.body then params.sink(route.body) end
        return 1, route.code, route.headers or {}
    end
    local saved = {}
    local fakes = {
        ["socketutil"] = { set_timeout = function() end, reset_timeout = function() end },
        ["ltn12"] = { sink = { table = function(t)
            return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
        end } },
        ["socket.http"] = { request = request },
        ["ssl.https"] = { request = request },
    }
    for name, fake in pairs(fakes) do
        saved[name] = package.loaded[name]
        package.loaded[name] = fake
    end
    local ok, err = pcall(body, Fetch.new("koreader", { user_agent = "spec" }), requests)
    for name in pairs(fakes) do package.loaded[name] = saved[name] end
    if not ok then error(err, 0) end
end

describe("Fetch (luasocket) conditional requests", function()
    it("sends the validators it is given", function()
        with_fake_socket({
            ["https://x.org/feed"] = { code = 200, body = "<rss/>",
                headers = { etag = '"v2"', ["last-modified"] = "Tue, 15 Jan 2026 04:47:54 GMT" } },
        }, function(fetch, requests)
            local body, err, code, info = fetch:get("https://x.org/feed",
                { etag = '"v1"', last_modified = "Mon, 14 Jan 2026 00:00:00 GMT" })
            assert_.equal("<rss/>", body)
            assert_.nil_(err)
            assert_.equal(200, code)
            assert_.equal('"v1"', requests[1].headers["If-None-Match"])
            assert_.equal("Mon, 14 Jan 2026 00:00:00 GMT", requests[1].headers["If-Modified-Since"])
            assert_.equal('"v2"', info.etag)
            assert_.equal("Tue, 15 Jan 2026 04:47:54 GMT", info.last_modified)
            assert_.equal("https://x.org/feed", info.url)
            assert_.nil_(info.moved_to)
        end)
    end)

    it("sends no validators when it has none", function()
        with_fake_socket({ ["https://x.org/feed"] = { code = 200, body = "x" } },
            function(fetch, requests)
                fetch:get("https://x.org/feed")
                assert_.nil_(requests[1].headers["If-None-Match"])
                assert_.nil_(requests[1].headers["If-Modified-Since"])
            end)
    end)

    it("strips line breaks so a stored validator cannot inject a header", function()
        with_fake_socket({ ["https://x.org/feed"] = { code = 200, body = "x" } },
            function(fetch, requests)
                fetch:get("https://x.org/feed", { etag = '"a"\r\nX-Evil: 1' })
                assert_.equal('"a"X-Evil: 1', requests[1].headers["If-None-Match"])
            end)
    end)

    it("reports a 304 as not modified, distinct from an error", function()
        with_fake_socket({ ["https://x.org/feed"] = { code = 304, headers = { etag = '"v1"' } } },
            function(fetch)
                local body, err, code, info = fetch:get("https://x.org/feed", { etag = '"v1"' })
                assert_.nil_(body)
                assert_.equal(Fetch.NOT_MODIFIED, err)
                assert_.equal(304, code)
                assert_.equal('"v1"', info.etag)
            end)
    end)

    it("still reports other failures as HTTP errors", function()
        with_fake_socket({ ["https://x.org/feed"] = { code = 404 } }, function(fetch)
            local body, err, code = fetch:get("https://x.org/feed")
            assert_.nil_(body)
            assert_.equal("HTTP 404", err)
            assert_.equal(404, code)
        end)
    end)
end)

describe("Fetch (luasocket) redirects", function()
    it("follows http to https and reports a permanent move", function()
        with_fake_socket({
            ["http://x.org/feed"] = { code = 301, headers = { location = "https://x.org/feed" } },
            ["https://x.org/feed"] = { code = 200, body = "ok" },
        }, function(fetch, requests)
            local body, _, _, info = fetch:get("http://x.org/feed")
            assert_.equal("ok", body)
            assert_.equal(false, requests[1].redirect)
            assert_.equal("https://x.org/feed", info.url)
            assert_.equal("https://x.org/feed", info.moved_to)
        end)
    end)

    it("resolves a relative Location", function()
        with_fake_socket({
            ["https://x.org/old/feed"] = { code = 308, headers = { location = "../new/feed" } },
            ["https://x.org/new/feed"] = { code = 200, body = "ok" },
        }, function(fetch)
            local _, _, _, info = fetch:get("https://x.org/old/feed")
            assert_.equal("https://x.org/new/feed", info.moved_to)
        end)
    end)

    it("does not remember a chain that includes a temporary hop", function()
        for _, temporary in ipairs({ 302, 303, 307 }) do
            with_fake_socket({
                ["http://x.org/a"] = { code = 301, headers = { location = "http://x.org/b" } },
                ["http://x.org/b"] = { code = temporary, headers = { location = "https://cdn.x.org/c" } },
                ["https://cdn.x.org/c"] = { code = 200, body = "ok" },
            }, function(fetch)
                local body, _, _, info = fetch:get("http://x.org/a")
                assert_.equal("ok", body)
                assert_.equal("https://cdn.x.org/c", info.url)
                assert_.nil_(info.moved_to, "after a " .. temporary)
            end)
        end
    end)

    it("gives up on a redirect loop", function()
        with_fake_socket({
            ["http://x.org/a"] = { code = 302, headers = { location = "http://x.org/b" } },
            ["http://x.org/b"] = { code = 302, headers = { location = "http://x.org/a" } },
        }, function(fetch, requests)
            local body, err = fetch:get("http://x.org/a")
            assert_.nil_(body)
            assert_.equal("too many redirects", err)
            assert_.truthy(#requests <= 11)
        end)
    end)
end)

describe("Fetch.parse_header_dump", function()
    it("splits curl -D output into one entry per response", function()
        local dump = table.concat({
            "HTTP/1.1 301 Moved Permanently", "Location: https://x.org/feed", "",
            "HTTP/1.1 100 Continue", "",
            "HTTP/2 200", "ETag: \"abc\"", "Last-Modified: Tue, 15 Jan 2026 04:47:54 GMT", "",
        }, "\r\n")
        local responses = Fetch.parse_header_dump(dump)
        assert_.len(2, responses)
        assert_.equal(301, responses[1].code)
        assert_.equal("https://x.org/feed", responses[1].headers.location)
        assert_.equal(200, responses[2].code)
        assert_.equal('"abc"', responses[2].headers.etag)
        assert_.equal("Tue, 15 Jan 2026 04:47:54 GMT", responses[2].headers["last-modified"])
    end)

    it("copes with nothing at all", function()
        assert_.len(0, Fetch.parse_header_dump(nil))
    end)
end)

describe("Fetch.parse_cache_control", function()
    it("reads max-age", function()
        assert_.equal(600, (Fetch.parse_cache_control("public, max-age=600")))
    end)

    it("takes Age off what is left", function()
        assert_.equal(500, (Fetch.parse_cache_control("max-age=600", "100")))
        assert_.equal(0, (Fetch.parse_cache_control("max-age=600", "9000")))
    end)

    it("treats no-cache as zero, whatever max-age says", function()
        assert_.equal(0, (Fetch.parse_cache_control("max-age=600, no-cache")))
    end)

    it("reports no-store", function()
        local max_age, no_store = Fetch.parse_cache_control("No-Store")
        assert_.nil_(max_age)
        assert_.truthy(no_store)
    end)

    it("ignores s-maxage and a missing header", function()
        assert_.nil_((Fetch.parse_cache_control("s-maxage=600")))
        assert_.nil_((Fetch.parse_cache_control(nil)))
    end)
end)

describe("Fetch (luasocket) cache headers", function()
    it("reports max-age less Age, and no-store, from the final response", function()
        with_fake_socket({
            ["https://x.org/feed"] = { code = 200, body = "x",
                headers = { ["cache-control"] = "max-age=300, no-store", age = "60" } },
        }, function(fetch)
            local _, _, _, info = fetch:get("https://x.org/feed")
            assert_.equal(240, info.max_age)
            assert_.truthy(info.no_store)
        end)
    end)

    it("reports nothing when there is no Cache-Control", function()
        with_fake_socket({ ["https://x.org/feed"] = { code = 200, body = "x" } }, function(fetch)
            local _, _, _, info = fetch:get("https://x.org/feed")
            assert_.nil_(info.max_age)
            assert_.falsy(info.no_store)
        end)
    end)
end)
