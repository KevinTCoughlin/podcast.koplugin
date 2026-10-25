local Url = require("feed.url")

describe("Url.resolve", function()
    -- RFC 3986 section 5.4, against its own base URI.
    local BASE = "http://a/b/c/d;p?q"
    local CASES = {
        -- 5.4.1 normal examples
        { "g:h", "g:h" }, { "g", "http://a/b/c/g" }, { "./g", "http://a/b/c/g" },
        { "g/", "http://a/b/c/g/" }, { "/g", "http://a/g" }, { "//g", "http://g" },
        { "?y", "http://a/b/c/d;p?y" }, { "g?y", "http://a/b/c/g?y" },
        { "#s", "http://a/b/c/d;p?q#s" }, { "g#s", "http://a/b/c/g#s" },
        { "g?y#s", "http://a/b/c/g?y#s" }, { ";x", "http://a/b/c/;x" },
        { "g;x", "http://a/b/c/g;x" }, { "g;x?y#s", "http://a/b/c/g;x?y#s" },
        { "", "http://a/b/c/d;p?q" }, { ".", "http://a/b/c/" }, { "./", "http://a/b/c/" },
        { "..", "http://a/b/" }, { "../", "http://a/b/" }, { "../g", "http://a/b/g" },
        { "../..", "http://a/" }, { "../../", "http://a/" }, { "../../g", "http://a/g" },
        -- 5.4.2 abnormal examples
        { "../../../g", "http://a/g" }, { "../../../../g", "http://a/g" },
        { "/./g", "http://a/g" }, { "/../g", "http://a/g" }, { "g.", "http://a/b/c/g." },
        { ".g", "http://a/b/c/.g" }, { "g..", "http://a/b/c/g.." }, { "..g", "http://a/b/c/..g" },
        { "./../g", "http://a/b/g" }, { "./g/.", "http://a/b/c/g/" },
        { "g/./h", "http://a/b/c/g/h" }, { "g/../h", "http://a/b/c/h" },
        { "g;x=1/./y", "http://a/b/c/g;x=1/y" }, { "g;x=1/../y", "http://a/b/c/y" },
        { "g?y/./x", "http://a/b/c/g?y/./x" }, { "g#s/../x", "http://a/b/c/g#s/../x" },
        { "http:g", "http:g" },
    }

    it("matches every example in RFC 3986 section 5.4", function()
        for _, case in ipairs(CASES) do
            assert_.equal(case[2], Url.resolve(BASE, case[1]), "reference " .. case[1])
        end
    end)

    it("trims the whitespace feeds wrap around URLs", function()
        assert_.equal("https://x.org/a.mp3", Url.resolve("https://x.org/feed", "\n  a.mp3  \n"))
    end)

    it("resolves against a host with no path", function()
        assert_.equal("https://x.org/a.mp3", Url.resolve("https://x.org", "a.mp3"))
    end)

    it("leaves the reference alone when there is no usable base", function()
        assert_.equal("a.mp3", Url.resolve(nil, "a.mp3"))
        assert_.equal("a.mp3", Url.resolve("relative/base", "a.mp3"))
        assert_.nil_(Url.resolve("https://x.org/", nil))
    end)
end)
