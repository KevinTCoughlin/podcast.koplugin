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

### Not yet
- No KOReader UI: no `_meta.lua`, no `main.lua`. Deferred until the sibling
  radio plugin's widget patterns are validated in the emulator.
