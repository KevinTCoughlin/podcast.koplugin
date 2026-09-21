local Xml = require("feed.xml")

local function collect(document)
    local events = {}
    for event in Xml.events(document) do events[#events + 1] = event end
    return events
end

local function texts(document)
    local out = {}
    for event in Xml.events(document) do
        if event.type == "text" then out[#out + 1] = event.text end
    end
    return out
end

describe("Xml.decode_entities", function()
    it("expands the standard five", function()
        assert_.equal("<a> & 'b' \"c\"",
            Xml.decode_entities("&lt;a&gt; &amp; &apos;b&apos; &quot;c&quot;"))
    end)

    it("expands decimal and hex character references", function()
        assert_.equal("\226\128\148", Xml.decode_entities("&#8212;"))
        assert_.equal("\226\128\148", Xml.decode_entities("&#x2014;"))
    end)

    it("leaves an unknown reference as written", function()
        -- Dropping it would turn "AT&T" into "ATT".
        assert_.equal("AT&T Inc", Xml.decode_entities("AT&T Inc"))
        assert_.equal("&nosuchthing;", Xml.decode_entities("&nosuchthing;"))
    end)
end)

describe("Xml.events", function()
    it("reports open, text and close in order", function()
        local events = collect("<a><b>hi</b></a>")
        assert_.equal("open", events[1].type)
        assert_.equal("a", events[1].name)
        assert_.equal("b", events[2].name)
        assert_.equal("text", events[3].type)
        assert_.equal("hi", events[3].text)
        assert_.equal("close", events[4].type)
        assert_.equal("b", events[4].name)
        assert_.equal("a", events[5].name)
    end)

    it("emits a close for a self-closing tag", function()
        local events = collect('<enclosure url="http://x/a.mp3"/>')
        assert_.len(2, events)
        assert_.equal("open", events[1].type)
        assert_.equal("close", events[2].type)
        assert_.equal("http://x/a.mp3", events[1].attrs.url)
    end)

    it("keeps element nesting balanced across a whole document", function()
        local depth = 0
        for event in Xml.events("<a><b/><c><d>x</d></c></a>") do
            if event.type == "open" then depth = depth + 1
            elseif event.type == "close" then depth = depth - 1 end
        end
        assert_.equal(0, depth)
    end)

    it("reads attributes in either quote style and decodes them", function()
        local events = collect("<img src='http://x/a.png?a=1&amp;b=2' alt=\"x&amp;y\"/>")
        assert_.equal("http://x/a.png?a=1&b=2", events[1].attrs.src)
        assert_.equal("x&y", events[1].attrs.alt)
    end)

    it("lower-cases tag and attribute names", function()
        local events = collect('<Enclosure URL="http://x/a.mp3"/>')
        assert_.equal("enclosure", events[1].name)
        assert_.equal("http://x/a.mp3", events[1].attrs.url)
    end)

    it("preserves namespace prefixes verbatim", function()
        assert_.equal("itunes:duration", collect("<itunes:duration>1</itunes:duration>")[1].name)
    end)

    it("treats CDATA as literal text", function()
        assert_.deep_equal({ "Raw <b>bold</b> & co" },
            texts("<t><![CDATA[Raw <b>bold</b> & co]]></t>"))
    end)

    it("skips comments, even ones containing tags", function()
        assert_.deep_equal({ "x" }, texts("<t><!-- <fake>ignored</fake> -->x</t>"))
    end)

    it("skips the XML declaration and the DOCTYPE", function()
        local events = collect('<?xml version="1.0"?><!DOCTYPE rss><a/>')
        assert_.equal("a", events[1].name)
    end)

    it("drops whitespace-only text between elements", function()
        assert_.len(0, texts("<a>\n  <b/>\n</a>"))
    end)

    it("returns nothing for junk rather than raising", function()
        assert_.len(0, collect(""))
        assert_.len(0, collect(nil))
        -- An unterminated tag ends the stream instead of looping.
        collect("<a><b")
    end)
end)
