local Parser = require("feed.parser")

local function rss(channel_extra, items)
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">',
        "<channel>",
        "<title>Test Show</title>",
        "<description>A show about testing.</description>",
        "<language>en-US</language>",
        "<itunes:author>Test Author</itunes:author>",
        channel_extra or "",
        items or "",
        "</channel></rss>",
    }, "\n")
end

local FULL_ITEM = [==[
<item>
  <title>Episode One</title>
  <guid isPermaLink="false">guid-1</guid>
  <pubDate>Tue, 15 Jan 2026 04:47:54 +0000</pubDate>
  <description><![CDATA[<p>Show <b>notes</b> &amp; links.</p>]]></description>
  <itunes:duration>1:02:03</itunes:duration>
  <itunes:episode>7</itunes:episode>
  <itunes:season>2</itunes:season>
  <itunes:explicit>no</itunes:explicit>
  <link>https://example.org/ep1</link>
  <enclosure url="https://example.org/ep1.mp3" type="audio/mpeg" length="29360128"/>
</item>
]==]

describe("Parser.parse channel metadata", function()
    it("reads the channel fields", function()
        local feed = Parser.parse(rss(nil, FULL_ITEM))
        assert_.equal("Test Show", feed.channel.title)
        assert_.equal("A show about testing.", feed.channel.description)
        assert_.equal("en-US", feed.channel.language)
        assert_.equal("Test Author", feed.channel.author)
    end)

    it("does not let an episode title overwrite the channel title", function()
        -- The bug this pins: both elements are <title>, and a naive parser
        -- ends up naming the show after its most recent episode.
        assert_.equal("Test Show", Parser.parse(rss(nil, FULL_ITEM)).channel.title)
    end)

    it("takes the artwork from itunes:image", function()
        local feed = Parser.parse(rss('<itunes:image href="http://x/art.png"/>', FULL_ITEM))
        assert_.equal("http://x/art.png", feed.channel.image)
    end)

    it("falls back to the plain image element", function()
        local feed = Parser.parse(rss("<image><url>http://x/old.png</url></image>", FULL_ITEM))
        assert_.equal("http://x/old.png", feed.channel.image)
    end)

    it("rejects a document that is not a feed", function()
        assert_.nil_((Parser.parse("<html><body>hi</body></html>")))
        assert_.nil_((Parser.parse("not xml at all")))
        assert_.nil_((Parser.parse(nil)))
        assert_.truthy(select(2, Parser.parse("<html></html>")))
    end)
end)

describe("Parser.parse episodes", function()
    it("extracts everything an episode list and a player need", function()
        local episode = Parser.parse(rss(nil, FULL_ITEM)).episodes[1]
        assert_.equal("Episode One", episode.title)
        assert_.equal("guid-1", episode.guid)
        assert_.equal("https://example.org/ep1.mp3", episode.url)
        assert_.equal("audio/mpeg", episode.mime)
        assert_.equal(29360128, episode.size)
        assert_.equal(3723, episode.duration)
        assert_.equal(1768452474, episode.published)
        assert_.equal(7, episode.episode_number)
        assert_.equal(2, episode.season)
        assert_.equal(false, episode.explicit)
        assert_.equal("https://example.org/ep1", episode.page_url)
    end)

    it("flattens show-notes HTML for display", function()
        local episode = Parser.parse(rss(nil, FULL_ITEM)).episodes[1]
        assert_.equal("Show notes & links.", episode.description)
    end)

    it("drops items with no audio enclosure", function()
        -- This is what separates a podcast feed from an ordinary RSS feed, and
        -- what KOReader's existing RSS plugins ignore.
        local feed = Parser.parse(rss(nil, [[
            <item><title>Text only</title><guid>g1</guid></item>
            <item><title>A PDF</title><guid>g2</guid>
              <enclosure url="http://x/a.pdf" type="application/pdf" length="1"/></item>
        ]] .. FULL_ITEM))
        assert_.len(1, feed.episodes)
        assert_.equal("Episode One", feed.episodes[1].title)
    end)

    it("accepts audio identified only by its extension", function()
        -- Publishers mislabel or omit the MIME type often enough to matter.
        local feed = Parser.parse(rss(nil, [[
            <item><title>E</title><guid>g</guid>
              <enclosure url="http://x/a.m4a" length="1"/></item>
        ]]))
        assert_.len(1, feed.episodes)
    end)

    it("excludes video enclosures", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>V</title><guid>g</guid>
              <enclosure url="http://x/a.mp4" type="video/mp4" length="1"/></item>
        ]]))
        assert_.len(0, feed.episodes)
    end)

    it("falls back to media:content when there is no enclosure", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>M</title><guid>g</guid>
              <media:content url="http://x/a.mp3" type="audio/mpeg" filesize="99"/></item>
        ]]))
        assert_.len(1, feed.episodes)
        assert_.equal(99, feed.episodes[1].size)
    end)

    it("uses the enclosure URL as identity when there is no guid", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>E</title>
              <enclosure url="http://x/a.mp3" type="audio/mpeg" length="1"/></item>
        ]]))
        assert_.equal("http://x/a.mp3", feed.episodes[1].guid)
    end)

    it("survives an episode missing date and duration", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>E</title><guid>g</guid>
              <enclosure url="http://x/a.mp3" type="audio/mpeg"/></item>
        ]]))
        local episode = feed.episodes[1]
        assert_.nil_(episode.published)
        assert_.nil_(episode.duration)
        assert_.nil_(episode.size)
        assert_.equal("E", episode.title)
    end)

    it("names an untitled episode rather than leaving it blank", function()
        local feed = Parser.parse(rss(nil, [[
            <item><guid>g</guid><enclosure url="http://x/a.mp3" type="audio/mpeg"/></item>
        ]]))
        assert_.equal("(untitled episode)", feed.episodes[1].title)
    end)

    it("keeps feed order, which is newest-first by convention", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>New</title><guid>g1</guid>
              <pubDate>Tue, 15 Jan 2026 00:00:00 +0000</pubDate>
              <enclosure url="http://x/1.mp3" type="audio/mpeg"/></item>
            <item><title>Old</title><guid>g2</guid>
              <pubDate>Mon, 14 Jan 2026 00:00:00 +0000</pubDate>
              <enclosure url="http://x/2.mp3" type="audio/mpeg"/></item>
        ]]))
        assert_.equal("New", feed.episodes[1].title)
        assert_.truthy(feed.episodes[1].published > feed.episodes[2].published)
    end)

    it("stops at max_episodes so a huge feed need not be fully parsed", function()
        local items = {}
        for index = 1, 50 do
            items[#items + 1] = string.format([[
                <item><title>E%d</title><guid>g%d</guid>
                  <enclosure url="http://x/%d.mp3" type="audio/mpeg"/></item>]],
                index, index, index)
        end
        local feed = Parser.parse(rss(nil, table.concat(items)), { max_episodes = 5 })
        assert_.len(5, feed.episodes)
        assert_.equal("E5", feed.episodes[5].title)
    end)

    it("prefers description over itunes:summary when both are present", function()
        local feed = Parser.parse(rss(nil, [[
            <item><title>E</title><guid>g</guid>
              <description>Real notes</description>
              <itunes:summary>Duplicate notes</itunes:summary>
              <enclosure url="http://x/a.mp3" type="audio/mpeg"/></item>
        ]]))
        assert_.equal("Real notes", feed.episodes[1].description)
    end)
end)

describe("Parser.parse Atom feeds", function()
    local ATOM = [[
    <?xml version="1.0"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Atom Show</title>
      <subtitle>Described here</subtitle>
      <entry>
        <title>Atom Episode</title>
        <id>tag:example.org,2026:1</id>
        <published>2026-01-15T04:47:54Z</published>
        <link rel="alternate" href="https://example.org/page"/>
        <link rel="enclosure" type="audio/mpeg" length="123" href="https://example.org/a.mp3"/>
      </entry>
    </feed>
    ]]

    it("reads the channel and the enclosure link", function()
        local feed = Parser.parse(ATOM)
        assert_.equal("Atom Show", feed.channel.title)
        assert_.len(1, feed.episodes)
        local episode = feed.episodes[1]
        assert_.equal("Atom Episode", episode.title)
        assert_.equal("https://example.org/a.mp3", episode.url)
        assert_.equal("tag:example.org,2026:1", episode.guid)
        assert_.equal(1768452474, episode.published)
    end)

    it("does not mistake the alternate link for the audio", function()
        assert_.equal("https://example.org/page", Parser.parse(ATOM).episodes[1].page_url)
    end)
end)

describe("Parser.strip_html", function()
    it("turns block tags into line breaks and drops the rest", function()
        assert_.equal("One\n\nTwo", Parser.strip_html("<p>One</p><p>Two</p>"))
        assert_.equal("One\nTwo", Parser.strip_html("One<br/>Two"))
    end)

    it("decodes entities exposed by removing tags", function()
        assert_.equal("a & b", Parser.strip_html("<i>a &amp; b</i>"))
    end)

    it("squeezes runs of whitespace", function()
        assert_.equal("a b", Parser.strip_html("a    \t b"))
    end)

    it("returns nil for nothing", function()
        assert_.nil_(Parser.strip_html(nil))
        assert_.nil_(Parser.strip_html("<p></p>"))
    end)
end)

describe("Parser.parse relative URLs", function()
    local FEED = "https://example.org/shows/feed.xml"

    it("resolves enclosure, link and artwork against the feed URL", function()
        local feed = Parser.parse(rss([[
            <link>/shows/</link>
            <itunes:image href="art/cover.png"/>
        ]], [[
            <item><guid>a</guid><link>ep1.html</link>
              <itunes:image href="/img/ep1.png"/>
              <enclosure url="audio/ep1.mp3" type="audio/mpeg"/></item>
        ]]), { base_url = FEED })
        assert_.equal("https://example.org/shows/", feed.channel.page_url)
        assert_.equal("https://example.org/shows/art/cover.png", feed.channel.image)
        local episode = feed.episodes[1]
        assert_.equal("https://example.org/shows/audio/ep1.mp3", episode.url)
        assert_.equal("https://example.org/shows/ep1.html", episode.page_url)
        assert_.equal("https://example.org/img/ep1.png", episode.image)
    end)

    it("resolves the channel <image><url>", function()
        local feed = Parser.parse(rss("<image><url>logo.png</url></image>", FULL_ITEM),
            { base_url = FEED })
        assert_.equal("https://example.org/shows/logo.png", feed.channel.image)
    end)

    it("resolves media:content too", function()
        local feed = Parser.parse(rss(nil, [[
            <item><guid>a</guid><media:content url="m.mp3" type="audio/mpeg"/></item>
        ]]), { base_url = FEED })
        assert_.equal("https://example.org/shows/m.mp3", feed.episodes[1].url)
    end)

    it("leaves absolute URLs untouched", function()
        local feed = Parser.parse(rss(nil, FULL_ITEM), { base_url = FEED })
        assert_.equal("https://example.org/ep1.mp3", feed.episodes[1].url)
    end)

    it("honours a nested Atom xml:base, and only inside its element", function()
        local feed = Parser.parse([[
            <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://cdn.example.org/podcast/">
              <title>Based</title>
              <link href="home"/>
              <entry xml:base="2026/">
                <id>one</id>
                <link rel="enclosure" type="audio/mpeg" href="one.mp3"/>
                <link rel="alternate" href="/pages/one"/>
              </entry>
              <entry>
                <id>two</id>
                <link rel="enclosure" type="audio/mpeg" href="two.mp3"/>
              </entry>
            </feed>
        ]], { base_url = FEED })
        assert_.equal("https://cdn.example.org/podcast/home", feed.channel.page_url)
        assert_.equal("https://cdn.example.org/podcast/2026/one.mp3", feed.episodes[1].url)
        assert_.equal("https://cdn.example.org/pages/one", feed.episodes[1].page_url)
        assert_.equal("https://cdn.example.org/podcast/two.mp3", feed.episodes[2].url)
    end)

    it("stamps each episode with its feed, defaulting to the base URL", function()
        assert_.equal(FEED, Parser.parse(rss(nil, FULL_ITEM), { base_url = FEED })
            .episodes[1].feed_url)
        assert_.equal("https://old.example.org/feed", Parser.parse(rss(nil, FULL_ITEM),
            { base_url = FEED, feed_url = "https://old.example.org/feed" }).episodes[1].feed_url)
    end)
end)

describe("Parser.parse show notes and dates", function()
    it("prefers content:encoded when it is richer than description", function()
        local feed = Parser.parse(rss(nil, [==[
            <item><guid>a</guid><description>Short teaser.</description>
              <content:encoded><![CDATA[<p>Full notes, with <a href="x">links</a> and more.</p>]]></content:encoded>
              <enclosure url="http://x/a.mp3" type="audio/mpeg"/></item>
        ]==]))
        assert_.equal("Full notes, with links and more.", feed.episodes[1].description)
    end)

    it("keeps description when content:encoded is no richer", function()
        local feed = Parser.parse(rss(nil, [[
            <item><guid>a</guid><description>The full description here.</description>
              <content:encoded>Short</content:encoded>
              <enclosure url="http://x/a.mp3" type="audio/mpeg"/></item>
        ]]))
        assert_.equal("The full description here.", feed.episodes[1].description)
    end)

    it("uses Atom content over a shorter summary", function()
        local feed = Parser.parse([[
            <feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>
              <entry><id>1</id><summary>Brief</summary>
                <content type="html">&lt;p&gt;The long-form &amp;amp; complete notes&lt;/p&gt;</content>
                <link rel="enclosure" type="audio/mpeg" href="https://x/a.mp3"/></entry>
            </feed>
        ]])
        assert_.equal("The long-form & complete notes", feed.episodes[1].description)
    end)

    it("clamps a future publication date to now", function()
        local now = 1768452474   -- 2026-01-15T04:47:54Z
        local feed = Parser.parse(rss(nil, [[
            <item><guid>future</guid><pubDate>Fri, 01 Jan 2100 00:00:00 +0000</pubDate>
              <enclosure url="http://x/f.mp3" type="audio/mpeg"/></item>
            <item><guid>past</guid><pubDate>Mon, 12 Jan 2026 00:00:00 +0000</pubDate>
              <enclosure url="http://x/p.mp3" type="audio/mpeg"/></item>
        ]]), { now = now })
        assert_.equal(now, feed.episodes[1].published)
        assert_.equal("Fri, 01 Jan 2100 00:00:00 +0000", feed.episodes[1].published_raw)
        assert_.truthy(feed.episodes[2].published < now)
    end)
end)

describe("Parser.discover", function()
    local PAGE = "https://example.org/show/"

    it("finds the first advertised feed and resolves it", function()
        local html = [[
            <html><head>
              <link rel="stylesheet" href="/s.css">
              <link rel="alternate" type="text/html" href="/other">
              <LINK REL="alternate" TYPE="application/rss+xml" title="Podcast" HREF="feed.xml?a=1&amp;b=2">
              <link rel="alternate" type="application/atom+xml" href="/atom.xml">
            </head></html>
        ]]
        assert_.equal("https://example.org/show/feed.xml?a=1&b=2", Parser.discover(html, PAGE))
    end)

    it("accepts Atom, unquoted attributes and multi-token rel", function()
        local html = [[<head><link type=application/atom+xml rel="feed alternate" href=/a.xml /></head>]]
        assert_.equal("https://example.org/a.xml", Parser.discover(html, PAGE))
    end)

    it("honours <base href>", function()
        local html = [[<head><base href="https://cdn.example.org/x/">
            <link rel="alternate" type="application/rss+xml" href="rss"></head>]]
        assert_.equal("https://cdn.example.org/x/rss", Parser.discover(html, PAGE))
    end)

    it("returns nil when the page advertises no feed", function()
        assert_.nil_(Parser.discover("<html><head><title>x</title></head></html>", PAGE))
        assert_.nil_(Parser.discover(nil, PAGE))
    end)
end)
