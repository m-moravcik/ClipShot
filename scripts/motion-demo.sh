#!/bin/bash
# Play ClipShot's motion live, for review and recording. See ClipShot/Preview/MotionDemo.swift.
#
#   scripts/motion-demo.sh           # light
#   scripts/motion-demo.sh dark      # dark
#   REDUCE=1 scripts/motion-demo.sh  # Peg's side as with Reduce Motion on
#
# A floating window at the top left of the main screen plays a scripted 30 s sequence on
# demo data: the tour's Try it (the symbols, the invitation, Peg in step with the menu bar,
# the first-copy celebration), the floating preview (arrival, badge, hover, a swipe held past
# the dismiss point, "+1"), the popover's Undo returning a row, the Undo strip closing and
# the list filling up again, its header's nod, and Peg's attention, pause and resume. Then the
# app quits. Record the screen meanwhile (for example with QuickTime) and crop to the window.
#
# Like scripts/screenshots.sh, it never reads or changes the screenshot settings, folder,
# clipboard or preferences of this Mac: everything is demo data under build/motion-scratch.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="${1:-light}"
case "$SCHEME" in
    light|dark) ;;
    *) echo "unknown appearance: $SCHEME (light or dark)" >&2; exit 2 ;;
esac
DERIVED="build/screenshots-dd"
APP="$DERIVED/Build/Products/Debug/ClipShot.app"

xcodegen generate >/dev/null
xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build

SCRATCH="$PWD/build/motion-scratch"
# The previous run's demo folders go to the Trash (never rm).
if [ -e "$SCRATCH" ]; then
    /usr/bin/trash "$SCRATCH" >/dev/null
fi
mkdir -p "$SCRATCH"

CLIPSHOT_MOTION_DEMO="$SCHEME" CLIPSHOT_MOTION_REDUCE="${REDUCE:-0}" CLIPSHOT_SCREENSHOTS_SCRATCH="$SCRATCH" \
    LLVM_PROFILE_FILE="$PWD/$DERIVED/motion.profraw" \
    "$APP/Contents/MacOS/ClipShot" \
    -AppleLanguages "(en)" \
    -AppleLocale "en_US" \
    -clipshot.copyEnabled YES \
    -clipshot.markupTipShown YES \
    -clipshot.launchAtLoginIntent YES
