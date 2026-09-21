--[[--
Feed date parsing.

RSS mandates RFC 822 dates and Atom mandates RFC 3339, and podcast feeds in the
wild contain both plus a long tail of near-misses. Episodes have to sort
correctly and retention policies have to compare against "now", so this returns
a real epoch rather than a string.

`os.time` is not used for the conversion: it interprets its argument as *local*
time, which would shift every episode by the device's timezone -- and an
e-reader's clock is frequently set to something wrong. The civil-date
arithmetic here is exact and timezone-free.
]]

local DateTime = {}

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

--- Named zones still seen in RSS. Anything unrecognised is treated as UTC,
-- which is the least-wrong default for sorting.
local ZONES = {
    ut = 0, utc = 0, gmt = 0, z = 0,
    est = -5, edt = -4, cst = -6, cdt = -5,
    mst = -7, mdt = -6, pst = -8, pdt = -7,
}

--- Days since 1970-01-01 for a proleptic Gregorian y/m/d (Hinnant's algorithm).
local function days_from_civil(year, month, day)
    year = year - (month <= 2 and 1 or 0)
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local day_of_year = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365
        + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100)
        + day_of_year
    return era * 146097 + day_of_era - 719468
end

local function to_epoch(year, month, day, hour, minute, second, offset_seconds)
    if not (year and month and day) then return nil end
    if month < 1 or month > 12 or day < 1 or day > 31 then return nil end
    return days_from_civil(year, month, day) * 86400
        + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
        - (offset_seconds or 0)
end

--- Parses "+0100", "-05:00", "GMT", "Z" into seconds east of UTC.
local function parse_offset(text)
    if not text or text == "" then return 0 end
    text = text:gsub("%s", "")
    local sign, hours, minutes = text:match("^([+%-])(%d%d):?(%d%d)$")
    if sign then
        local seconds = tonumber(hours) * 3600 + tonumber(minutes) * 60
        return (sign == "-") and -seconds or seconds
    end
    local zone = ZONES[text:lower()]
    if zone then return zone * 3600 end
    return 0
end

--- RFC 822 / 2822: "Tue, 15 Jan 2026 04:47:54 +0000" (weekday optional).
function DateTime.parse_rfc822(text)
    if type(text) ~= "string" then return nil end
    local body = text:gsub("^%s*%a%a%a%s*,%s*", ""):gsub("^%s+", "")
    local day, month_name, year, hour, minute, second, zone =
        body:match("^(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)%s+(%d%d?):(%d%d):?(%d?%d?)%s*(.*)$")
    if not day then
        -- No time component at all, which some feeds do.
        day, month_name, year = body:match("^(%d%d?)%s+(%a%a%a)%a*%s+(%d%d%d%d)")
        if not day then return nil end
        hour, minute, second, zone = 0, 0, 0, ""
    end
    local month = MONTHS[month_name:lower()]
    if not month then return nil end
    return to_epoch(tonumber(year), month, tonumber(day),
        tonumber(hour) or 0, tonumber(minute) or 0, tonumber(second) or 0,
        parse_offset(zone))
end

--- RFC 3339 / ISO 8601: "2026-01-15T04:47:54Z", with optional fractional seconds.
function DateTime.parse_iso8601(text)
    if type(text) ~= "string" then return nil end
    local year, month, day, hour, minute, second, zone =
        text:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):?(%d?%d?)%.?%d*%s*(.*)$")
    if not year then
        year, month, day = text:match("^%s*(%d%d%d%d)%-(%d%d)%-(%d%d)%s*$")
        if not year then return nil end
        hour, minute, second, zone = 0, 0, 0, ""
    end
    return to_epoch(tonumber(year), tonumber(month), tonumber(day),
        tonumber(hour) or 0, tonumber(minute) or 0, tonumber(second) or 0,
        parse_offset(zone))
end

--- Tries both formats. Returns epoch seconds, or nil.
function DateTime.parse(text)
    return DateTime.parse_rfc822(text) or DateTime.parse_iso8601(text)
end

--- Parses an iTunes duration: "3723", "62:03" or "1:02:03" -- all three are
-- legal per Apple's spec and all three occur.
function DateTime.parse_duration(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("%s", "")
    if text == "" then return nil end

    local parts = {}
    for part in text:gmatch("[^:]+") do
        local number = tonumber(part)
        if not number then return nil end
        parts[#parts + 1] = math.floor(number)
    end

    if #parts == 1 then return parts[1] end
    if #parts == 2 then return parts[1] * 60 + parts[2] end
    if #parts == 3 then return parts[1] * 3600 + parts[2] * 60 + parts[3] end
    return nil
end

--- "1:02:03" / "12:03" for display.
function DateTime.format_duration(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then return nil end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remainder = math.floor(seconds % 60)
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, remainder)
    end
    return string.format("%d:%02d", minutes, remainder)
end

return DateTime
