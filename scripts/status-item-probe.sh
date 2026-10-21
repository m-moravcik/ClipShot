#!/bin/bash
# Check that Peg's moments reach the real status item while the popover is open.
# See ClipShot/Preview/StatusItemProbe.swift.
#
#   scripts/status-item-probe.sh            # into build/status-item-probe
#
# A Debug build runs its real MenuBarExtra on demo data, clicks its own status item button
# in-process (the popover opens for a few seconds), then plays a Copy, a Move to Trash and an
# Undo from the popover's rows. It records the image the status item button holds at each
# step (button-*.png) and a log (probe.log) of how many distinct images each moment put there
# and whether each matches the frame the model drew. Then it quits.
#
# Nothing looks at the screen or at another app: the images are read from ClipShot's own
# button, in its own process. Like scripts/screenshots.sh, it never reads or changes this
# Mac's screenshot settings, folder, clipboard or preferences: the model is demo data under
# build/status-item-probe-scratch, and its Trash is a folder there.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="${DERIVED:-build/screenshots-dd}"
APP="$DERIVED/Build/Products/Debug/ClipShot.app"
# xcodebuild registers the Debug build with LaunchServices (and screenshots.sh registers it
# again for its icon). Unregistered on exit, so this Mac's Shortcuts app never lists the
# Debug build's actions as a second ClipShot. Only this build folder's app, never
# /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_debug() {
    case "$APP" in /*) "$LSREGISTER" -u "$APP" ;; *) "$LSREGISTER" -u "$PWD/$APP" ;; esac >/dev/null 2>&1 || true
}
trap unregister_debug EXIT
OUT="$PWD/build/status-item-probe"
SCRATCH="$PWD/build/status-item-probe-scratch"

xcodegen generate >/dev/null
xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build

# The previous run's output and demo folders go to the Trash (never rm).
for dir in "$OUT" "$SCRATCH"; do
    if [ -e "$dir" ]; then
        /usr/bin/trash "$dir" >/dev/null
    fi
done
mkdir -p "$OUT" "$SCRATCH"

CLIPSHOT_STATUS_PROBE="$OUT" CLIPSHOT_SCREENSHOTS_SCRATCH="$SCRATCH" \
    LLVM_PROFILE_FILE="$PWD/$DERIVED/probe.profraw" \
    "$APP/Contents/MacOS/ClipShot" \
    -AppleLanguages "(en)" \
    -AppleLocale "en_US" \
    -clipshot.copyEnabled YES \
    -clipshot.markupTipShown YES \
    -clipshot.launchAtLoginIntent YES
