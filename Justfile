# podcast.koplugin — development tasks
# Requires: luajit, mpv. No luarocks, no KOReader checkout.

default: check test

# Run the test suite
test:
    luajit spec/run.lua

# Syntax-check every Lua file
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    while IFS= read -r file; do
        if ! luajit -bl "$file" /dev/null >/dev/null 2>&1; then
            echo "SYNTAX: $file"
            luajit -bl "$file" /dev/null 2>&1 | head -3
            failed=1
        fi
    done < <(find podcast.koplugin spec -name '*.lua')
    [ "$failed" -eq 0 ] && echo "syntax ok"

# Run the dev harness, e.g. `just cli episodes 1`
cli *ARGS:
    ./bin/kopod {{ARGS}}

# Parse a feed already on disk, without re-fetching
parse FILE *ARGS:
    ./bin/kopod parse {{FILE}} {{ARGS}}

# Pull koaudio updates from shoutkit.koplugin, where it is authored
vendor-koaudio:
    git subtree pull --prefix=podcast.koplugin/koaudio \
        https://github.com/KevinTCoughlin/shoutkit.koplugin.git koaudio --squash

# Build a zip of just the plugin directory, for sideloading
package:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p dist
    rm -f dist/podcast.koplugin.zip
    zip -qr dist/podcast.koplugin.zip podcast.koplugin -x '*.log'
    echo "dist/podcast.koplugin.zip"
