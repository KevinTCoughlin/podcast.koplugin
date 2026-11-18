# Changelog

## Unreleased

### Added
- `feed/xml.lua`: a pull parser for XML, emitting events rather than building a
  tree, so a multi-megabyte feed is processed in bounded memory.
- `feed/parser.lua`: RSS 2.0 and Atom → channel and episodes. Keeps only items
  with an audio enclosure, falls back to `media:content`, and sniffs the
  extension when a publisher mislabels the MIME type.
- `feed/datetime.lua`: RFC 822 and RFC 3339 dates using timezone-independent
  civil-date arithmetic, plus iTunes duration parsing.
- `library.lua`: subscriptions and per-episode state (played, position,
  downloaded) that survives a feed refresh, persisted as a Lua literal.
- `net/fetch.lua`: feed retrieval and resumable episode download, including
  detecting a server that ignores `Range`.
- `bin/kopod` development harness, and 68 tests with no external dependencies.
- `koaudio` vendored from shoutkit.koplugin via `git subtree`.

- KOReader UI: Tools → Podcasts. Subscriptions list with add-by-URL,
  refresh-all and unsubscribe; episode list showing download state, position
  and show notes; now-playing with ±30 s seek and position persistence. Feeds
  and downloads run in a dismissable subprocess, and cancelling a download
  leaves the partial file it resumes from.
- `tools/emulator.sh`: loads the plugin into a real KOReader release build and
  drives its widgets headless (18 checks), plus `tools/install-kobo.sh`.

- Polite feed fetching, per https://kevincox.ca/2022/05/06/rss-feed-best-practices/:
  - Conditional requests. Refresh-all and `kopod refresh` send the stored
    `ETag`/`Last-Modified` as `If-None-Match`/`If-Modified-Since`; a 304 keeps
    the subscription as it was without downloading or parsing the feed.
  - Redirects on the luasocket path, which could not follow http → https.
    Both paths follow up to 10 hops, and when every hop is permanent (301/308)
    the subscription moves to the new URL, episode state included.
  - Relative enclosure, link and artwork URLs are resolved against the feed
    URL and Atom `xml:base` (`feed/url.lua`, an RFC 3986 resolver).
  - Adding a show's web page finds the feed it advertises with
    `<link rel="alternate" type="application/rss+xml">` (or Atom).
  - `content:encoded` and Atom `content` are used as show notes when richer
    than the description, and a future publication date is clamped to now.
  - The episode list is cached (`net/feedcache.lua`, in KOReader's
    `cache/podcast-feeds`). Within the feed's `Cache-Control: max-age`
    (capped at a day) opening a show makes no request and does not wake the
    Wi-Fi; after it, the request is conditional and a 304 reuses the cached
    body. `no-store` and responses with no validators or max-age are not kept,
    and only subscribed feeds stay in the cache.

### Changed
- Episode state is keyed by feed URL and guid, since a guid is only unique
  within its feed. Existing guid-only state migrates to the first feed that
  asks for it. Download file names gain a short per-feed prefix.

### Not yet
- Only the mpv audio backend exists, so playback does not work on any e-reader.
  Everything else — subscribing, refreshing, downloading — does.
