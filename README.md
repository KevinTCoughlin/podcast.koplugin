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

> **Status: early, but it runs as a KOReader plugin.** Subscribe, refresh,
> browse episodes, download and play — all working and verified against a real
> KOReader build (`just emulator-smoke`, 18 checks including a live 2.1 MB feed
> and a real download through KOReader's own luasec). The gap is **audio
> backends**: only mpv is implemented, so on an actual e-reader everything
> except playback works. See [ROADMAP.md](ROADMAP.md).

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
  main.lua           menu wiring
  ui/
    subscriptions.lua  the show list, add-by-URL, refresh-all
    episodes.lua       episode list, download and playback actions
    nowplaying.lua     transport, seek, and position persistence
  feed/
    xml.lua          pull parser: events, not a tree
    parser.lua       RSS 2.0 + Atom -> channel + episodes with audio
    datetime.lua     RFC 822 / RFC 3339 dates, iTunes durations
  net/fetch.lua      feed GET, and resumable episode download
  library.lua        subscriptions + per-episode state, as a Lua literal
  koaudio/           ← vendored from shoutkit.koplugin (git subtree)
```

### Five decisions worth knowing about

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

**Feeds and downloads run in a subprocess.** `Trapper:dismissableRunInSubprocess`
forks, so parsing a multi-megabyte feed cannot freeze the reader and the user
can cancel. Dismissing SIGKILLs the child — which for a download leaves the
partial file that `net/fetch.lua` resumes from, so cancelling at 90 % costs
nothing.

**Advertised metadata is not trusted.** Real feeds get it wrong: one episode in
our test set advertises 17 MB and 18:05 but is actually 19.8 MB and 21:39.
Enclosure length is used for display only; the downloader and the player use
what they actually get.

## Development

Needs `luajit` and `mpv`. No luarocks, no KOReader checkout.

```sh
just test              # 68 unit tests, dependency-free runner
just check             # syntax-check every Lua file
just emulator-smoke    # load into real KOReader, assert 18 widget checks
just emulator          # launch real KOReader to click around (Tools -> Podcasts)
just cli list
just install-kobo      # copy onto a Kobo mounted as USB mass storage
just vendor-koaudio    # pull koaudio updates from shoutkit.koplugin
```

`just emulator-smoke` is the one that matters. Unit tests cannot catch a wrong
KOReader API call, because they never load KOReader's frontend; the emulator
harness instantiates the real widgets and fails on exactly that. It downloads a
KOReader release build for you and runs headless via SDL's dummy video driver,
so it needs no display and works over SSH.

## Installing on a device

Copy the inner `podcast.koplugin/` directory into KOReader's `plugins/`. On Kobo
that is `.adds/koreader/plugins/` on the KOBOeReader partition, and
`just install-kobo` finds it for you — the device exposes no storage until you
tap **Connect** on its screen.

Then **Tools → Podcasts**. Subscribing, refreshing and downloading all work over
the device's Wi-Fi, so episodes can be waiting on it. Playing reports **"No
audio backend on this device"** until the ALSA/BlueALSA backend exists.

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
