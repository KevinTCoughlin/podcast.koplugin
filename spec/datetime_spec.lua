local DateTime = require("feed.datetime")

-- 2026-01-15T04:47:54Z, cross-checked against a reference implementation.
local REFERENCE = 1768452474

describe("DateTime.parse_rfc822", function()
    it("parses the canonical RSS form", function()
        assert_.equal(REFERENCE, DateTime.parse("Tue, 15 Jan 2026 04:47:54 +0000"))
    end)

    it("applies a numeric zone offset", function()
        assert_.equal(REFERENCE, DateTime.parse("Tue, 15 Jan 2026 05:47:54 +0100"))
        assert_.equal(REFERENCE, DateTime.parse("Tue, 15 Jan 2026 03:47:54 -0100"))
    end)

    it("applies the named zones still found in feeds", function()
        assert_.equal(REFERENCE, DateTime.parse("15 Jan 2026 04:47:54 GMT"))
        assert_.equal(REFERENCE + 86400, DateTime.parse("15 Jan 2026 23:47:54 EST"))
    end)

    it("tolerates a missing weekday and missing seconds", function()
        assert_.equal(REFERENCE - 54, DateTime.parse("15 Jan 2026 04:47 +0000"))
    end)

    it("handles a date with no time at all", function()
        assert_.equal(REFERENCE - (4 * 3600 + 47 * 60 + 54), DateTime.parse("15 Jan 2026"))
    end)
end)

describe("DateTime.parse_iso8601", function()
    it("parses the canonical Atom form", function()
        assert_.equal(REFERENCE, DateTime.parse("2026-01-15T04:47:54Z"))
    end)

    it("ignores fractional seconds and applies the offset", function()
        assert_.equal(REFERENCE, DateTime.parse("2026-01-15T04:47:54.123Z"))
        assert_.equal(REFERENCE, DateTime.parse("2026-01-15T05:47:54+01:00"))
    end)

    it("handles a bare date", function()
        assert_.equal(REFERENCE - (4 * 3600 + 47 * 60 + 54), DateTime.parse("2026-01-15"))
    end)
end)

describe("DateTime.parse", function()
    it("returns nil for anything unparseable instead of guessing", function()
        assert_.nil_(DateTime.parse("not a date"))
        assert_.nil_(DateTime.parse(""))
        assert_.nil_(DateTime.parse(nil))
        assert_.nil_(DateTime.parse("32 Foo 2026 00:00:00 +0000"))
    end)

    it("is timezone-independent, unlike os.time", function()
        -- The whole reason for the civil-date arithmetic: an e-reader's clock
        -- and zone are frequently wrong, and episode order must not depend on them.
        assert_.equal(0, DateTime.parse("Thu, 01 Jan 1970 00:00:00 +0000"))
        assert_.equal(946684800, DateTime.parse("Sat, 01 Jan 2000 00:00:00 +0000"))
    end)

    it("handles dates before the epoch", function()
        assert_.equal(-86400, DateTime.parse("Wed, 31 Dec 1969 00:00:00 +0000"))
    end)
end)

describe("DateTime.parse_duration", function()
    it("accepts all three forms Apple's spec allows", function()
        assert_.equal(3723, DateTime.parse_duration("3723"))
        assert_.equal(3723, DateTime.parse_duration("62:03"))
        assert_.equal(3723, DateTime.parse_duration("1:02:03"))
    end)

    it("returns nil rather than a wrong number", function()
        assert_.nil_(DateTime.parse_duration("about an hour"))
        assert_.nil_(DateTime.parse_duration(""))
        assert_.nil_(DateTime.parse_duration(nil))
    end)
end)

describe("DateTime.format_duration", function()
    it("drops the hour component when there is none", function()
        assert_.equal("1:02:03", DateTime.format_duration(3723))
        assert_.equal("12:03", DateTime.format_duration(723))
        assert_.equal("0:07", DateTime.format_duration(7))
    end)

    it("returns nil for a duration there is no point displaying", function()
        assert_.nil_(DateTime.format_duration(0))
        assert_.nil_(DateTime.format_duration(nil))
    end)
end)
