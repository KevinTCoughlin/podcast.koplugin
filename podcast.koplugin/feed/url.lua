--[[--
Resolves a URL reference against a base URL, per RFC 3986 section 5.2.

Feeds are allowed to use relative URLs -- for enclosures, links and artwork --
and they mean "relative to the feed's own URL", or to an Atom `xml:base` in
scope. A reader that hands `episodes/1.mp3` straight to the downloader has
nothing to download.

Why not `socket.url.absolute`: luasocket is not available where the test suite
runs (plain LuaJIT, no luarocks), and its resolver follows the older RFC 2396,
which disagrees with 3986 on cases such as a query-only reference (`?y`). Forty
lines of the RFC's own algorithm, tested against the RFC's own examples, is the
smaller dependency.
]]

local Url = {}

--- Splits a URL into scheme, authority, path, query and fragment. A component
-- that is absent is nil; one that is present but empty is "".
function Url.split(reference)
    local scheme, rest = reference:match("^(%a[%w+.%-]*):(.*)$")
    if not scheme then rest = reference end

    local fragment
    local hash = rest:find("#", 1, true)
    if hash then fragment, rest = rest:sub(hash + 1), rest:sub(1, hash - 1) end

    local query
    local question = rest:find("?", 1, true)
    if question then query, rest = rest:sub(question + 1), rest:sub(1, question - 1) end

    local authority
    if rest:sub(1, 2) == "//" then
        local slash = rest:find("/", 3, true)
        authority = rest:sub(3, (slash or #rest + 1) - 1)
        rest = slash and rest:sub(slash) or ""
    end
    return scheme, authority, rest, query, fragment
end

--- RFC 3986 5.2.4. Each output entry is one segment with its leading "/", so
-- "remove the last segment" is removing the last entry.
local function remove_dot_segments(path)
    local input, output = path, {}
    while input ~= "" do
        if input:sub(1, 3) == "../" then
            input = input:sub(4)
        elseif input:sub(1, 2) == "./" then
            input = input:sub(3)
        elseif input:sub(1, 3) == "/./" then
            input = input:sub(3)
        elseif input == "/." then
            input = "/"
        elseif input:sub(1, 4) == "/../" then
            input = input:sub(4)
            output[#output] = nil
        elseif input == "/.." then
            input = "/"
            output[#output] = nil
        elseif input == "." or input == ".." then
            input = ""
        else
            local segment = input:match("^/?[^/]*")
            output[#output + 1] = segment
            input = input:sub(#segment + 1)
        end
    end
    return table.concat(output)
end

local function merge(base_authority, base_path, path)
    if base_authority and base_path == "" then return "/" .. path end
    return (base_path:match("^(.*/)") or "") .. path
end

--- Returns `reference` resolved against `base`. Whitespace around the
-- reference is dropped, since feeds pad URLs with newlines often enough. If
-- the base is missing or itself relative, the reference is returned as is:
-- there is nothing better to resolve it against.
function Url.resolve(base, reference)
    if not reference then return nil end
    reference = reference:gsub("^%s+", ""):gsub("%s+$", "")
    if not base or base == "" then return reference end

    local r_scheme, r_authority, r_path, r_query, r_fragment = Url.split(reference)
    local scheme, authority, path, query

    if r_scheme then
        scheme, authority, path, query = r_scheme, r_authority, remove_dot_segments(r_path), r_query
    else
        local b_scheme, b_authority, b_path, b_query = Url.split(base)
        if not b_scheme then return reference end
        scheme = b_scheme
        if r_authority then
            authority, path, query = r_authority, remove_dot_segments(r_path), r_query
        else
            authority = b_authority
            if r_path == "" then
                path = b_path
                query = r_query or b_query
            else
                if r_path:sub(1, 1) == "/" then
                    path = remove_dot_segments(r_path)
                else
                    path = remove_dot_segments(merge(b_authority, b_path, r_path))
                end
                query = r_query
            end
        end
    end

    return scheme .. ":"
        .. (authority and ("//" .. authority) or "")
        .. path
        .. (query and ("?" .. query) or "")
        .. (r_fragment and ("#" .. r_fragment) or "")
end

return Url
