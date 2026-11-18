--[[--
HTTP for feeds and episode downloads.

Two operations with very different shapes, which is why this is not the same
module as a plain API client:

  * `get` pulls a feed into memory. Feeds are megabytes, which is fine.
  * `download` streams an episode to disk and **resumes**. Episodes are tens to
    hundreds of megabytes over an e-reader's Wi-Fi, which drops, and KOReader
    powers the radio down aggressively. Re-downloading 200 MB because the
    screen blanked at 90% is not acceptable, so every download is a Range
    request continuing whatever is already on disk.

Same two-implementation seam as the radio plugin's transport: curl for
development and CI, luasocket for on-device. Tests inject a fake.

`get` is a polite feed reader (https://kevincox.ca/2022/05/06/rss-feed-best-practices/):

  * **Conditional requests.** Pass the `etag` and `last_modified` a previous
    fetch returned, and an unchanged feed costs a 304 with no body instead of
    megabytes. That comes back as `nil, Fetch.NOT_MODIFIED, 304, info`.
  * **Redirects, and remembering them.** Both paths follow up to
    MAX_REDIRECTS hops. When every hop was permanent (301/308), `info.moved_to`
    is the new URL, and the caller should update the subscription so the old
    one can eventually be retired by its publisher.

  * **Cache-Control.** `info.max_age` is how many more seconds the response
    may be reused without asking again (max-age less Age; 0 for no-cache),
    and `info.no_store` is set when the server asked for it not to be kept.
    `net/feedcache.lua` is what acts on them.

The full return is `body, err, code, info`, with `info` holding `url` (where the
body actually came from), `moved_to`, `etag`, `last_modified`, `max_age` and
`no_store`.
]]

local Url = require("feed.url")

local Fetch = {}
Fetch.__index = Fetch

local DEFAULT_TIMEOUT = 30
local MAX_REDIRECTS = 10

--- Distinct from every other error string, so callers can compare against it.
Fetch.NOT_MODIFIED = "not modified"

local REDIRECT_CODES = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }
local PERMANENT_CODES = { [301] = true, [308] = true }

--- Header values go on a command line and into a request; a stored validator
-- with a line break in it must not be able to inject a header.
local function header_value(value)
    if value == nil then return nil end
    value = tostring(value):gsub("[\r\n]", "")
    if value == "" then return nil end
    return value
end

local function conditional_headers(headers, opts)
    headers["If-None-Match"] = header_value(opts.etag)
    headers["If-Modified-Since"] = header_value(opts.last_modified)
    return headers
end

--- The URL a redirect chain should be remembered as, or nil: only when every
-- hop was permanent, and the chain actually went somewhere else.
local function permanent_target(original, hops, final)
    if #hops == 0 or final == original then return nil end
    for _, code in ipairs(hops) do
        if not PERMANENT_CODES[code] then return nil end
    end
    return final
end

--- The common tail of both `get` implementations.
local function finish_get(code, body, info)
    if code == 304 then return nil, Fetch.NOT_MODIFIED, code, info end
    if code < 200 or code >= 300 then return nil, "HTTP " .. code, code, info end
    return body, nil, code, info
end

--- Reads the freshness a response grants from its Cache-Control and Age
-- headers. Returns max_age, no_store: max_age is seconds of reuse left (0 when
-- the response must be revalidated every time, nil when the header says
-- nothing about it). s-maxage is for shared caches and does not apply here.
function Fetch.parse_cache_control(value, age)
    if not value then return nil, false end
    value = tostring(value):lower()
    local max_age, no_cache, no_store
    for directive in value:gmatch("[^,]+") do
        directive = directive:gsub("^%s+", ""):gsub("%s+$", "")
        local seconds = directive:match('^max%-age%s*=%s*"?(%d+)"?$')
        if seconds then
            max_age = tonumber(seconds)
        elseif directive:match("^no%-cache") then
            no_cache = true
        elseif directive == "no-store" then
            no_store = true
        end
    end
    -- no-cache wins over a max-age in the same header: reuse only after asking.
    if no_cache then max_age = 0 end
    age = tonumber(age)
    if max_age and age and age > 0 then max_age = math.max(0, max_age - age) end
    return max_age, no_store or false
end

--- The `info` fields that come straight from the final response's headers,
-- which both transports give as a table of lowercase names.
local function header_info(info, headers)
    info.etag = headers["etag"]
    info.last_modified = headers["last-modified"]
    info.max_age, info.no_store =
        Fetch.parse_cache_control(headers["cache-control"], headers["age"])
    return info
end

--- Parses `curl -D` output: one block per response, redirects included.
-- Returns a list of { code =, headers = { lowercase-name = value } }.
-- Interim 1xx responses are dropped; they say nothing about the result.
function Fetch.parse_header_dump(text)
    local responses = {}
    local current
    for line in ((text or "") .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        local code = line:match("^HTTP/[%d%.]+%s+(%d%d%d)")
        if code then
            current = { code = tonumber(code), headers = {} }
            if current.code >= 200 then responses[#responses + 1] = current end
        elseif current then
            local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
            if name then current.headers[name:lower()] = value end
        end
    end
    return responses
end

local function shell_escape(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function file_size(path)
    local handle = io.open(path, "rb")
    if not handle then return 0 end
    local size = handle:seek("end") or 0
    handle:close()
    return size
end

local CurlFetch = {}
CurlFetch.__index = CurlFetch

function CurlFetch:get(url, opts)
    opts = opts or {}
    local temp = (os.getenv("TMPDIR") or "/tmp") .. "/kopod-" .. tostring(math.random(1e9))
    local body_path, header_path = temp, temp .. ".headers"
    local parts = {
        "curl", "-sS", "-L", "--max-redirs", tostring(MAX_REDIRECTS),
        "--max-time", tostring(opts.timeout or DEFAULT_TIMEOUT),
        "-A", shell_escape(self.user_agent),
        "-o", shell_escape(body_path),
        -- Every response's headers, redirects included: the hop codes are
        -- what says whether a move was permanent.
        "-D", shell_escape(header_path),
        "-w", "'%{http_code} %{url_effective}'",
    }
    for name, value in pairs(conditional_headers({}, opts)) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shell_escape(name .. ": " .. value)
    end
    parts[#parts + 1] = shell_escape(url)

    local pipe = io.popen(table.concat(parts, " ") .. " 2>/dev/null")
    if not pipe then
        os.remove(body_path)
        return nil, "cannot spawn curl"
    end
    local written = pipe:read("*a") or ""
    pipe:close()
    local code, final_url = written:match("^(%d+)%s*(%S*)")
    code = tonumber(code)

    local handle = io.open(body_path, "r")
    local body = handle and handle:read("*a") or nil
    if handle then handle:close() end
    os.remove(body_path)

    handle = io.open(header_path, "r")
    local responses = Fetch.parse_header_dump(handle and handle:read("*a"))
    if handle then handle:close() end
    os.remove(header_path)

    if not code or code == 0 then return nil, "request failed" end

    local hops = {}
    for index = 1, #responses - 1 do
        if REDIRECT_CODES[responses[index].code] then hops[#hops + 1] = responses[index].code end
    end
    if final_url == "" then final_url = url end
    local last = responses[#responses] or { headers = {} }
    return finish_get(code, body, header_info({
        url = final_url,
        moved_to = permanent_target(url, hops, final_url),
    }, last.headers))
end

--- Streams `url` into `path`, continuing a partial file if one is there.
-- Returns bytes_now_on_disk, err.
function CurlFetch:download(url, path, opts)
    opts = opts or {}
    local already = file_size(path)

    local parts = {
        "curl", "-sS", "-L",
        "--max-time", tostring(opts.timeout or 0),   -- 0 = no overall limit
        "--connect-timeout", "20",
        -- Give up on a connection that has stalled below 1 KiB/s for 30 s
        -- rather than holding the Wi-Fi radio on indefinitely.
        "--speed-limit", "1024", "--speed-time", "30",
        "-A", shell_escape(self.user_agent),
        "-o", shell_escape(path),
    }
    if already > 0 then
        -- `-C -` asks curl to work out the resume offset itself; a server that
        -- ignores Range makes curl restart from zero, which is correct, if slow.
        parts[#parts + 1] = "-C"
        parts[#parts + 1] = "-"
    end
    parts[#parts + 1] = shell_escape(url)

    local ok = os.execute(table.concat(parts, " ") .. " >/dev/null 2>&1")
    local size = file_size(path)

    local succeeded = (ok == true or ok == 0)
    if not succeeded then
        -- A partial file is kept on purpose: it is what the next attempt
        -- resumes from.
        if size > already then
            return size, "download interrupted (partial file kept)"
        end
        return size, "download failed"
    end
    if size == 0 then
        os.remove(path)
        return 0, "server returned an empty file"
    end
    return size, nil
end

local KoreaderFetch = {}
KoreaderFetch.__index = KoreaderFetch

function KoreaderFetch:get(url, opts)
    opts = opts or {}
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local headers = conditional_headers({ ["User-Agent"] = self.user_agent }, opts)

    -- Redirects are followed here rather than by luasocket, which cannot
    -- follow one across schemes -- and http -> https is the commonest
    -- redirect a feed has. It would also hide the hop codes we need.
    local current, hops = url, {}
    socketutil:set_timeout(opts.timeout or DEFAULT_TIMEOUT, opts.timeout or DEFAULT_TIMEOUT)
    while true do
        local client = current:match("^https:") and require("ssl.https") or require("socket.http")
        local sink = {}
        local ok, code, response_headers = client.request{
            url = current,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(sink),
            redirect = false,
        }
        if not ok then
            socketutil:reset_timeout()
            return nil, tostring(code or "request failed")
        end
        code = tonumber(code)
        response_headers = response_headers or {}

        local location = REDIRECT_CODES[code] and response_headers["location"]
        if location then
            if #hops >= MAX_REDIRECTS then
                socketutil:reset_timeout()
                return nil, "too many redirects", code
            end
            hops[#hops + 1] = code
            current = Url.resolve(current, location)
        else
            socketutil:reset_timeout()
            if not code then return nil, "HTTP " .. tostring(code) end
            return finish_get(code, table.concat(sink), header_info({
                url = current,
                moved_to = permanent_target(url, hops, current),
            }, response_headers))
        end
    end
end

function KoreaderFetch:download(url, path, opts)
    opts = opts or {}
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local client = url:match("^https:") and require("ssl.https") or require("socket.http")

    local already = file_size(path)
    local headers = { ["User-Agent"] = self.user_agent }
    if already > 0 then
        headers["Range"] = string.format("bytes=%d-", already)
    end

    -- Appending only makes sense if the server honours the Range request; a
    -- 200 instead of a 206 means it sent the whole body and we must overwrite.
    local mode = (already > 0) and "ab" or "wb"
    local handle, open_err = io.open(path, mode)
    if not handle then return already, tostring(open_err) end

    socketutil:set_timeout(opts.timeout or DEFAULT_TIMEOUT, opts.timeout or DEFAULT_TIMEOUT)
    local ok, code = client.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(handle),   -- closes the handle itself
    }
    socketutil:reset_timeout()

    code = tonumber(code)
    if not ok then
        local size = file_size(path)
        if size > already then return size, "download interrupted (partial file kept)" end
        return size, tostring(code or "request failed")
    end

    if already > 0 and code == 200 then
        -- Range was ignored: what is on disk now is the full body written after
        -- the stale prefix, so it is garbage. Start over.
        os.remove(path)
        return 0, "server ignored Range; retry from the beginning"
    end
    if code ~= 200 and code ~= 206 then
        return file_size(path), "HTTP " .. tostring(code)
    end
    return file_size(path), nil
end

--- `kind` is "auto", "curl", "koreader", or a table implementing get/download.
function Fetch.new(kind, opts)
    opts = opts or {}
    local user_agent = opts.user_agent or "podcast.koplugin/0.1.0"
    if type(kind) == "table" then return kind end

    if kind == nil or kind == "auto" then
        kind = pcall(require, "socketutil") and "koreader" or "curl"
    end
    if kind == "koreader" then
        return setmetatable({ user_agent = user_agent, kind = "koreader" }, KoreaderFetch)
    end
    return setmetatable({ user_agent = user_agent, kind = "curl" }, CurlFetch)
end

Fetch.file_size = file_size

return Fetch
