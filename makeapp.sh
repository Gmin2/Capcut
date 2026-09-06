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

# The part that changes every build. Outside the bundle so the app's identity
# (and its TCC grants) never change, but signed with the same identity: dyld
# enforces library validation on a direct exec, and refuses an unsigned load.
mkdir -p "$SUPPORT"
cp "$BUILT/libCutawayCore.dylib" "$SUPPORT/libCutawayCore.dylib"
# Ad-hoc, not the dev identity. Signing with the identity needs the private
# key, and macOS will block on a keychain dialog if its access control has been
# reset - which stalls every build. The host carries
# disable-library-validation instead, so an ad-hoc dylib loads fine.
codesign --force --sign - "$SUPPORT/libCutawayCore.dylib" 2>/dev/null || true

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
    codesign --force --entitlements Cutaway.entitlements --sign "$IDENTITY" "$APP"
    echo "HOST CHANGED - rebuilt and signed with $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "HOST CHANGED - rebuilt, ad-hoc signed"
fi
echo ">>> screen recording permission must be re-granted <<<"

# Convenience symlink so `cutaway <command>` works from anywhere. Runs the
# bundle's own binary, so it inherits the app's TCC grants.
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/$APP/Contents/MacOS/cutaway" "$HOME/.local/bin/cutaway"
