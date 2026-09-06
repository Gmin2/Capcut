#!/bin/bash
# Dev loop: rebuild, re-sign, kill the old instance, launch the new one.
# Always use this rather than double-clicking the app, otherwise you end up
# staring at a stale build wondering why your change did nothing.
set -e
cd "$(dirname "$0")"

./makeapp.sh "${1:-debug}" >/dev/null

pkill -f 'Cutaway.app/Contents/MacOS/cutaway' 2>/dev/null || true
while pgrep -f 'Cutaway.app/Contents/MacOS/cutaway' >/dev/null; do sleep 0.2; done

mkdir -p tmp/claude
rm -f tmp/claude/probe.txt
# -n spawns a new instance every time; without this the old ones pile up,
# keep stale dylibs loaded, and write to the same log.
pkill -9 -f 'Cutaway.app/Contents/MacOS/cutaway' 2>/dev/null || true
while pgrep -f 'Cutaway.app/Contents/MacOS/cutaway' >/dev/null; do sleep 0.1; done
open -n build/Cutaway.app

echo "launched  (cdhash $(codesign -d --verbose=4 build/Cutaway.app 2>&1 | awk -F= '/^CDHash/{print substr($2,1,12)}'))"
echo "output    tmp/claude/probe.txt"
