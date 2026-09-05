#!/bin/bash
# Builds Cutaway. The app bundle holds only a frozen loader; all real code goes
# into a dylib outside the bundle. The bundle is only rewritten and re-signed
# when the loader itself changes, which should be never. That is what keeps the
# TCC screen recording grant alive across rebuilds.
set -e
cd "$(dirname "$0")"

CONFIG=${1:-debug}
APP="build/Cutaway.app"
SUPPORT="$HOME/Library/Application Support/Cutaway"
BUILT=".build/$CONFIG"

if ! swift build --disable-sandbox -c "$CONFIG" 2>&1 | grep -v '^warning: /Users' ; then
    echo "!!! BUILD FAILED - app not updated !!!" >&2
    exit 1
fi
if ! swift build --disable-sandbox -c "$CONFIG" >/dev/null 2>&1; then
    echo "!!! BUILD FAILED - app not updated !!!" >&2
    exit 1
fi

# The part that changes every build. Never signed, never inside the bundle.
mkdir -p "$SUPPORT"
cp "$BUILT/libCutawayCore.dylib" "$SUPPORT/libCutawayCore.dylib"

# The part that must never change.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Compare against a stamp of the *unsigned* build output. Comparing against the
# copy inside the bundle would always differ, because signing rewrites it.
STAMP="build/.host.sha"
NEW=$(cat "$BUILT/cutaway" Info.plist.in 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
OLD=$(cat "$STAMP" 2>/dev/null || echo none)

if [ "$NEW" = "$OLD" ]; then
    echo "host unchanged, bundle untouched (permission preserved)"
    echo "reloaded $SUPPORT/libCutawayCore.dylib"
    exit 0
fi

cp "$BUILT/cutaway" "$APP/Contents/MacOS/cutaway"
echo "$NEW" > "$STAMP"
cat Info.plist.in > "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F\" '/Apple Development|Developer ID/ {print $2; exit}')

# No hardened runtime: it enables library validation, which would refuse to
# load our unsigned dylib. Not needed until we notarise.
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "HOST CHANGED - rebuilt and signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "HOST CHANGED - rebuilt, ad-hoc signed"
fi
echo ">>> screen recording permission must be re-granted <<<"
