#!/bin/bash
# Rebuild, kill every old instance, launch one, wait for a marker in the log.
# Stale instances holding old dylibs are the single most confusing failure in
# this project, so killing is not optional.
set -e
cd "$(dirname "$0")"
./makeapp.sh >/dev/null || { echo "BUILD FAILED"; exit 1; }
pkill -9 -f 'Cutaway.app/Contents/MacOS/cutaway' 2>/dev/null || true
while pgrep -f 'Cutaway.app/Contents/MacOS/cutaway' >/dev/null; do sleep 0.1; done
rm -f tmp/claude/probe.txt
for t in "$@"; do touch "$HOME/Library/Application Support/Cutaway/$t"; done
open -n build/Cutaway.app
