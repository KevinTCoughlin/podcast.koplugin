--[[--
A pull parser for XML, sized for podcast feeds.

It emits a flat stream of events instead of building a tree, and that is the
whole design. Podcast feeds are not small: a long-running show's feed is
several megabytes and carries a thousand `<item>` elements, each with a
description that may hold an entire HTML show-notes document. On a device with
256 MB of RAM and no swap, materialising that as nested Lua tables is how you
get an out-of-memory kill; consuming it one event at a time is not.

    for event in Xml.events(document) do
        -- event.type: "open" | "close" | "text"
        -- open:  event.name, event.attrs
        -- close: event.name
        -- text:  event.text  (entities already decoded)
    end

Deliberately not a conforming XML parser. It does not validate, it does not
resolve namespace prefixes to URIs (it hands back `itunes:duration` verbatim,
which is what every consumer actually matches on), and it does not process
internal DTD entities. Real-world podcast feeds are frequently not well-formed
anyway, and rejecting them would be worse than being lenient.
]]

local Xml = {}

local NAMED_ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    -- The handful that show up unescaped-but-named in real show notes.
    nbsp = "\194\160", ndash = "\226\128\147", mdash = "\226\128\148",
    lsquo = "\226\128\152", rsquo = "\226\128\153",
    ldquo = "\226\128\156", rdquo = "\226\128\157",
    hellip = "\226\128\166", trade = "\226\132\162",
    copy = "\194\169", reg = "\194\174", deg = "\194\176",
}

local function utf8_encode(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

--- Expands character and named entity references.
-- An unrecognised reference is left as written rather than dropped: a bare `&`
-- in a title is common, and turning "AT&T" into "ATT" is worse than leaving it.
function Xml.decode_entities(text)
    if not text or not text:find("&", 1, true) then return text end
    return (text:gsub("&(#?[%w]+);", function(reference)
        if reference:sub(1, 1) == "#" then
            local code
            if reference:sub(2, 2):lower() == "x" then
                code = tonumber(reference:sub(3), 16)
            else
                code = tonumber(reference:sub(2))
            end
            if code and code > 0 and code < 0x110000 then return utf8_encode(code) end
            return nil
        end
        return NAMED_ENTITIES[reference:lower()]
    end))
end

local function parse_attributes(source)
    local attrs = {}
    -- Handles both quote styles; unquoted attribute values are not valid XML
    -- and are not supported.
    for name, _quote, value in source:gmatch("([%w:_%-%.]+)%s*=%s*([\"'])(.-)%2") do
        attrs[name:lower()] = Xml.decode_entities(value)
    end
    return attrs
end

--- Returns an iterator over the document's events.
function Xml.events(document)
    if type(document) ~= "string" then
        return function() return nil end
    end

    local position = 1
    local length = #document
    -- Set when a self-closing tag has emitted its "open" and still owes a "close".
    local pending_close = nil

    return function()
        if pending_close then
            local name = pending_close
            pending_close = nil
            return { type = "close", name = name }
        end

        while position <= length do
            local open_at = document:find("<", position, true)

            if not open_at then
                local text = document:sub(position)
                position = length + 1
                if text:find("%S") then
                    return { type = "text", text = Xml.decode_entities(text) }
                end
                return nil
            end

            -- Character data before this tag.
            if open_at > position then
                local text = document:sub(position, open_at - 1)
                position = open_at
                if text:find("%S") then
                    return { type = "text", text = Xml.decode_entities(text) }
                end
            end

            local prefix4 = document:sub(open_at, open_at + 3)

            if prefix4 == "<!--" then
                local stop = document:find("-->", open_at + 4, true)
                position = stop and (stop + 3) or (length + 1)

            elseif document:sub(open_at, open_at + 8) == "<![CDATA[" then
                local stop = document:find("]]>", open_at + 9, true)
                local text = document:sub(open_at + 9, (stop or length + 1) - 1)
                position = stop and (stop + 3) or (length + 1)
                -- CDATA is literal: entities inside it are not references.
                if text ~= "" then return { type = "text", text = text } end

            elseif prefix4 == "<!DO" or prefix4 == "<!do" then
                local stop = document:find(">", open_at, true)
                position = stop and (stop + 1) or (length + 1)

            elseif document:sub(open_at + 1, open_at + 1) == "?" then
                local stop = document:find("?>", open_at, true)
                position = stop and (stop + 2) or (length + 1)

            else
                local stop = document:find(">", open_at + 1, true)
                if not stop then
                    position = length + 1
                    return nil
                end
                local body = document:sub(open_at + 1, stop - 1)
                position = stop + 1

                if body:sub(1, 1) == "/" then
                    local name = body:match("^/%s*([%w:_%-%.]+)")
                    if name then return { type = "close", name = name:lower() } end
                else
                    local self_closing = body:sub(-1) == "/"
                    if self_closing then body = body:sub(1, -2) end
                    local name, rest = body:match("^([%w:_%-%.]+)(.*)$")
                    if name then
                        name = name:lower()
                        if self_closing then pending_close = name end
                        return { type = "open", name = name, attrs = parse_attributes(rest) }
                    end
                end
            end
        end
        return nil
    end
end

return Xml
