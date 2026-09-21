--[[--
Turns a podcast feed into a channel and a list of episodes.

The thing that makes a podcast feed a *podcast* feed, rather than an ordinary
RSS feed, is the audio enclosure on each item -- and that is precisely what
KOReader's existing RSS plugins do not look at. `newsdownloader.koplugin`
renders items to HTML/EPUB and drops enclosures entirely (koreader#3065 has
asked for them since 2017); `rssreader.koplugin` and `miniflux.koplugin` are
text readers. So this parser's job is narrow: find the audio, and the metadata
needed to list, sort, resume and expire it.

Handles RSS 2.0 (what Apple requires, and therefore what essentially every
podcast publishes) and Atom, which turns up occasionally. Items with no audio
enclosure are dropped rather than carried as unplayable rows.

Built on the pull parser in feed/xml.lua, so a multi-megabyte feed with a
thousand episodes is processed one event at a time and never held as a tree.
]]

local DateTime = require("feed.datetime")
local Xml = require("feed.xml")

local Parser = {}

--- Enclosure MIME types we will play. Checked as a prefix so `audio/mpeg` and
-- `audio/mpeg3` both pass; video podcasts are excluded on purpose, since no
-- e-reader is going to play them.
local function is_audio_type(mime)
    if not mime or mime == "" then return nil end
    return mime:lower():match("^audio/") ~= nil
end

--- Falls back to the extension when a publisher omits or mislabels the type,
-- which is common enough to matter.
local AUDIO_EXTENSIONS = {
    mp3 = true, m4a = true, mp4a = true, aac = true, ogg = true, oga = true,
    opus = true, flac = true, wav = true, m4b = true, mp2 = true,
}

local function looks_like_audio(url, mime)
    if is_audio_type(mime) then return true end
    if not url then return false end
    local path = url:gsub("#.*$", ""):gsub("%?.*$", "")
    local extension = (path:match("%.([%w]+)$") or ""):lower()
    return AUDIO_EXTENSIONS[extension] == true
end

--- Tags whose text we collect, mapped to the field they populate. Namespaced
-- names are matched verbatim -- see the note in feed/xml.lua.
local ITEM_TEXT_FIELDS = {
    ["title"] = "title",
    ["guid"] = "guid",
    ["id"] = "guid",                        -- Atom
    ["pubdate"] = "published_raw",
    ["published"] = "published_raw",        -- Atom
    ["updated"] = "updated_raw",            -- Atom
    ["description"] = "description",
    ["summary"] = "description",
    ["itunes:summary"] = "itunes_summary",
    ["itunes:subtitle"] = "subtitle",
    ["itunes:duration"] = "duration_raw",
    ["itunes:episode"] = "episode_number",
    ["itunes:season"] = "season",
    ["itunes:explicit"] = "explicit",
    ["itunes:author"] = "author",
    ["link"] = "page_url",
}

local CHANNEL_TEXT_FIELDS = {
    ["title"] = "title",
    ["description"] = "description",
    ["subtitle"] = "description",
    ["itunes:summary"] = "summary",
    ["itunes:author"] = "author",
    ["language"] = "language",
    ["copyright"] = "copyright",
    ["link"] = "page_url",
}

local function trim(text)
    if not text then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return text
end

--- Collapses show-notes HTML to something displayable in a list.
-- Not a sanitiser and not trying to be: it strips tags, decodes what the tag
-- removal exposes, and squeezes whitespace.
function Parser.strip_html(text)
    if not text then return nil end
    local stripped = text
        :gsub("<br%s*/?>", "\n")
        :gsub("</p>", "\n\n")
        :gsub("<[^>]*>", "")
    stripped = Xml.decode_entities(stripped)
    return trim((stripped:gsub("[ \t]+", " "):gsub("\n%s*\n%s*\n+", "\n\n")))
end

local function finish_episode(raw)
    if not raw.url then return nil end

    local duration = DateTime.parse_duration(raw.duration_raw)
    local published = DateTime.parse(raw.published_raw)
        or DateTime.parse(raw.updated_raw)

    local description = raw.description or raw.itunes_summary

    return {
        -- A feed without guids is not unheard of; the enclosure URL is the
        -- next-best stable identity, and is what dedupes a refresh.
        guid = raw.guid or raw.url,
        title = raw.title or "(untitled episode)",
        url = raw.url,
        mime = raw.mime,
        -- Content-Length as advertised. Trusted for display only: publishers
        -- get it wrong, and the downloader uses the real response.
        size = tonumber(raw.length),
        duration = duration,
        published = published,
        published_raw = raw.published_raw,
        subtitle = trim(raw.subtitle),
        description = Parser.strip_html(description),
        episode_number = tonumber(raw.episode_number),
        season = tonumber(raw.season),
        explicit = (raw.explicit or ""):lower() == "yes" or raw.explicit == "true",
        page_url = raw.page_url,
        author = trim(raw.author),
        image = raw.image,
    }
end

--- Parses a feed document. Returns { channel =, episodes = }, or nil plus an
--- error. Never raises: a truncated download is an expected condition.
--
-- `opts.max_episodes` stops after that many episodes. Feeds are ordered
-- newest-first by convention, so this is a cheap way to avoid parsing ten
-- years of back catalogue on a slow device.
function Parser.parse(document, opts)
    opts = opts or {}
    if type(document) ~= "string" or not document:find("<", 1, true) then
        return nil, "not an XML document"
    end

    local channel = {}
    local episodes = {}

    -- Where we are: nil outside items, a raw table inside one. Channel-level
    -- tags are only collected while `item` is nil, which is what keeps a
    -- channel <title> from being overwritten by every episode <title>.
    local item = nil
    local current_tag = nil
    local text_chunks = nil
    local depth_in_item = 0
    local saw_feed_root = false

    for event in Xml.events(document) do
        local name = event.name

        if event.type == "open" then
            if name == "rss" or name == "feed" or name == "rdf:rdf" then
                saw_feed_root = true

            elseif name == "item" or name == "entry" then
                item = {}
                depth_in_item = 0

            elseif name == "enclosure" then
                -- RSS: <enclosure url type length/>
                local attrs = event.attrs
                if item and looks_like_audio(attrs.url, attrs.type) then
                    item.url = attrs.url
                    item.mime = attrs.type
                    item.length = attrs.length
                end

            elseif name == "media:content" then
                -- Some feeds carry the audio only as Media RSS.
                local attrs = event.attrs
                if item and not item.url and looks_like_audio(attrs.url, attrs.type) then
                    item.url = attrs.url
                    item.mime = attrs.type
                    item.length = attrs.filesize
                end

            elseif name == "link" then
                -- Atom: the enclosure is a <link rel="enclosure">, and the
                -- page URL is rel="alternate" or absent.
                local attrs = event.attrs
                if attrs.href then
                    if attrs.rel == "enclosure" then
                        if item and looks_like_audio(attrs.href, attrs.type) then
                            item.url = attrs.href
                            item.mime = attrs.type
                            item.length = attrs.length
                        end
                    elseif not attrs.rel or attrs.rel == "alternate" then
                        if item then
                            item.page_url = item.page_url or attrs.href
                        else
                            channel.page_url = channel.page_url or attrs.href
                        end
                    end
                end
                current_tag, text_chunks = name, {}

            elseif name == "itunes:image" then
                local href = event.attrs.href
                if href then
                    if item then item.image = item.image or href
                    else channel.image = channel.image or href end
                end

            elseif name == "url" then
                -- <image><url> at channel level.
                current_tag, text_chunks = "image_url", {}

            else
                current_tag, text_chunks = name, {}
            end

            if item then depth_in_item = depth_in_item + 1 end

        elseif event.type == "text" then
            if text_chunks then text_chunks[#text_chunks + 1] = event.text end

        elseif event.type == "close" then
            if name == "item" or name == "entry" then
                local episode = finish_episode(item or {})
                if episode then episodes[#episodes + 1] = episode end
                item = nil
                if opts.max_episodes and #episodes >= opts.max_episodes then
                    break
                end

            elseif current_tag == name
                or (current_tag == "image_url" and name == "url") then
                local text = trim(table.concat(text_chunks or {}))
                if text then
                    if item then
                        local field = ITEM_TEXT_FIELDS[name]
                        -- Never overwrite: the first occurrence wins, which
                        -- matters for feeds that repeat <link>.
                        if field and not item[field] then item[field] = text end
                    else
                        if current_tag == "image_url" then
                            channel.image = channel.image or text
                        else
                            local field = CHANNEL_TEXT_FIELDS[name]
                            if field and not channel[field] then channel[field] = text end
                        end
                    end
                end
                current_tag, text_chunks = nil, nil
            end

            if item then depth_in_item = depth_in_item - 1 end
        end
    end

    if not saw_feed_root then
        return nil, "not a recognised RSS or Atom feed"
    end

    channel.title = channel.title or "(untitled feed)"
    channel.description = Parser.strip_html(channel.description or channel.summary)

    return { channel = channel, episodes = episodes }
end

return Parser
