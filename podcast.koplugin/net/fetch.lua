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
]]

local Fetch = {}
Fetch.__index = Fetch

local DEFAULT_TIMEOUT = 30

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
    local body_path = (os.getenv("TMPDIR") or "/tmp") .. "/kopod-" .. tostring(math.random(1e9))
    local parts = {
        "curl", "-sS", "-L",
        "--max-time", tostring(opts.timeout or DEFAULT_TIMEOUT),
        "-A", shell_escape(self.user_agent),
        "-o", shell_escape(body_path),
        "-w", "'%{http_code}'",
    }
    parts[#parts + 1] = shell_escape(url)

    local pipe = io.popen(table.concat(parts, " ") .. " 2>/dev/null")
    if not pipe then
        os.remove(body_path)
        return nil, "cannot spawn curl"
    end
    local code = tonumber((pipe:read("*a") or ""):match("%d+"))
    pipe:close()

    local handle = io.open(body_path, "r")
    local body = handle and handle:read("*a") or nil
    if handle then handle:close() end
    os.remove(body_path)

    if not code or code == 0 then return nil, "request failed" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. code, code end
    return body, nil, code
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
    local client = url:match("^https:") and require("ssl.https") or require("socket.http")

    local sink = {}
    socketutil:set_timeout(opts.timeout or DEFAULT_TIMEOUT, opts.timeout or DEFAULT_TIMEOUT)
    local ok, code = client.request{
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = self.user_agent },
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()

    if not ok then return nil, tostring(code or "request failed") end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code), code end
    return table.concat(sink), nil, code
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
