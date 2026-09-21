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

### Not yet
- Only the mpv audio backend exists, so playback does not work on any e-reader.
  Everything else — subscribing, refreshing, downloading — does.
