# podcast.koplugin

Podcast subscriptions, episode downloads and playback for
[KOReader](https://github.com/koreader/koreader).

KOReader has three RSS plugins and **none of them look at audio enclosures** —
which is the one thing that makes a feed a podcast feed.
[`newsdownloader.koplugin`](https://github.com/koreader/koreader/wiki/News-downloader)
renders items to HTML/EPUB and drops enclosures; a
[request for them](https://github.com/koreader/koreader/issues/3065) has been
open since 2017. `rssreader.koplugin` and `miniflux.koplugin` are text readers.
A GitHub search for a KOReader podcast plugin returns nothing. So: this.

> **Status: early, and there is no KOReader UI yet.** The feed parser, the
> subscription store and the downloader work, are tested, and are exercisable
> end to end from a desktop via `bin/kopod`. The in-KOReader surface is
> deliberately deferred until the sibling radio plugin's widget patterns have
> been validated in the emulator, so they get written once rather than twice.
> See [ROADMAP.md](ROADMAP.md).

## What works today

```console
$ bin/kopod add https://feeds.npr.org/510289/podcast.xml
subscribed: Planet Money

$ bin/kopod episodes 1 --limit 2
Planet Money

  1. The Domino’s Pizza Tracker Theory of Everything
     2026-09-18  ·  32:22  ·  30 MB
  2. How investing is getting riskier (Two Indicators)
     2026-09-16  ·  18:05  ·  17 MB  ·  downloaded  ·  at 0:13

$ bin/kopod resume 1 2 --seconds 8
playing local file
backend: mpv
[playing] 0:00 / 21:39
resumed at 0:13
[playing] 0:14 / 21:39
saved position: 0:19
```

Subscribe → refresh → list → download (resumable) → play from disk → position
tracked and persisted → resume where you stopped.

Verified against real feeds, including a **19.3 MB, 2983-episode** one:

| Feed | Size | Episodes | Parse time | Lua heap |
|---|---|---|---|---|
| Planet Money | 2.1 MB | 355 | 0.05 s | +2.7 MB |
| Lex Fridman | 2.0 MB | 503 | 0.11 s | +1.2 MB |
| The Daily | 19.3 MB | 2983 | 0.40 s | +3.0 MB |
| The Daily, `max_episodes = 25` | 19.3 MB | 25 | 0.00 s | +0.7 MB |

## Design

```
podcast.koplugin/
  feed/
    xml.lua          pull parser: events, not a tree
    parser.lua       RSS 2.0 + Atom -> channel + episodes with audio
    datetime.lua     RFC 822 / RFC 3339 dates, iTunes durations
  net/fetch.lua      feed GET, and resumable episode download
  library.lua        subscriptions + per-episode state, as a Lua literal
  koaudio/           ← vendored from shoutkit.koplugin (git subtree)
```

### Four decisions worth knowing about

**Events, not a tree.** A long-running show's feed is megabytes and carries a
thousand `<item>` elements, each of which may hold an entire HTML show-notes
document. On a 256 MB device with no swap, materialising that as nested Lua
tables is how you get an OOM kill. `feed/xml.lua` emits a flat event stream and
`parser.lua` consumes it one event at a time — hence the numbers above.

**Episode state lives apart from the feed.** A refresh replaces the episode
list wholesale. What must survive it is the part the user created: played,
position, downloaded. Keyed by guid, stored separately, and there is a test
pinning exactly that.

**Every download resumes.** Episodes are tens to hundreds of megabytes over
Wi-Fi that drops, on a device that powers its radio down aggressively.
Re-downloading 200 MB because the screen blanked at 90 % is not acceptable, so
a partial file is always kept and always continued with a Range request. The
luasocket path also detects a server that *ignores* Range and starts over
rather than appending onto a stale prefix.

**Advertised metadata is not trusted.** Real feeds get it wrong: one episode in
our test set advertises 17 MB and 18:05 but is actually 19.8 MB and 21:39.
Enclosure length is used for display only; the downloader and the player use
what they actually get.

## Development

Needs `luajit` and `mpv`. No luarocks, no KOReader checkout.

```sh
just test            # 68 tests, dependency-free runner
just check           # syntax-check every Lua file
just cli list
just vendor-koaudio   # pull koaudio updates from shoutkit.koplugin
```

State lives in `$KOPOD_HOME` (default `~/.kopod`), never in KOReader's settings.

### The shared audio core

`podcast.koplugin/koaudio/` is **vendored, not authored here.** It comes from
[`shoutkit.koplugin`](https://github.com/KevinTCoughlin/shoutkit.koplugin) via
`git subtree`, because the device-specific audio plumbing — GStreamer on Kindle,
ALSA plus BlueALSA on Kobo, MediaPlayer on Android — is the last thing that
should exist in two forks.

Edit it *there* and pull it in here:

```sh
just vendor-koaudio
```

The HTTP layer is deliberately **not** shared. Radio needs a small JSON API
client; podcasts need resumable streaming to disk. Different enough that
sharing one module would mean a module that does neither job well.

## Licence

AGPL-3.0, matching KOReader itself.
