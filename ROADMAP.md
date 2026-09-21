# Roadmap

## v0.1 — the core, off-device ✅

- [x] `feed/xml.lua`: pull parser handling CDATA, entities, namespaces, comments
- [x] `feed/parser.lua`: RSS 2.0 + Atom → channel + episodes, audio enclosures
      only, `media:content` fallback, extension sniffing for mislabelled types
- [x] `feed/datetime.lua`: RFC 822 and RFC 3339, timezone-independent
- [x] `library.lua`: subscriptions and per-episode state that survives a refresh
- [x] `net/fetch.lua`: feed GET and resumable episode download
- [x] `bin/kopod` harness: subscribe → download → play → resume
- [x] 68 tests; verified against three real feeds up to 19.3 MB / 2983 episodes

## v0.2 — the KOReader surface

Deliberately after shoutkit.koplugin's UI is validated in the emulator, so the
`Menu` / `Trapper` / `NetworkMgr` patterns are written once.

- [ ] `_meta.lua` and `main.lua`: Tools → Podcasts
- [ ] Subscriptions list, add-by-URL, refresh (Trapper-wrapped, cancellable)
- [ ] Episode list with download state, duration and position
- [ ] Download queue with progress, and a "download on next connect" mode —
      an e-reader is usually offline when you decide you want an episode
- [ ] Now-playing with a real scrubber, which radio does not need and podcasts
      cannot do without

## v0.3 — the things that make it usable daily

- [ ] Playback speed. Needs resampling in the backend, so it is a `koaudio`
      change, not a change here.
- [ ] Sleep timer
- [ ] Retention: auto-delete played episodes, cap per-show storage
- [ ] Auto-refresh on connect, with a per-show episode limit

## v0.4 — discovery

- [ ] Search by show name rather than pasting a feed URL
      ([Podcast Index](https://podcastindex.org/) is free and open; the iTunes
      Search API needs no key either)
- [ ] OPML import and export, so moving in and out is not a trap

## Later

- [ ] Chapters (`podcast:chapters`, and ID3 chapter frames)
- [ ] Transcripts (`podcast:transcript`) — the one podcast feature an e-reader
      is genuinely *better* at than a phone
- [ ] Audiobookshelf as an alternative source; it already manages podcast
      libraries server-side, and `absclient.lua` in audiobook.koplugin is prior art
- [ ] Publish to the `koreader-plugin` topic once a device backend works

## Explicitly not planned

- **Video podcasts.** Excluded at the parser.
- **Our own audio decoding.** That belongs in `koaudio`, shared with the radio
  plugin, not here.
