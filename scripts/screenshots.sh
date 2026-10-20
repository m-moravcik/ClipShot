#!/bin/bash
# Render the README screenshots, the app icon, the menu bar states and the portfolio
# banner from the app itself. See ClipShot/Preview/ScreenshotHarness.swift.
#
#   scripts/screenshots.sh        # English, into build/screenshots/en
#   scripts/screenshots.sh sk     # Slovak, for the web.pexelo portfolio
#
# Writes, in -light and -dark: popover, popover-paused, popover-attention, popover-full
# (every row at once, so long translations reach the height cap), attention-* (one per
# attention row), settings-{general,capture,retention,about}, settings-general-replayed,
# settings-capture-attention (the destination guard), onboarding-* (every tour step, and
# Try it blocked by an attention), hero (popover under the menu bar, README) and banner
# (1920x1080). Plus icon.png, menubar-states.png and menubar-optical-size.png (the states
# beside VibeRes and Eject Guard, sized as the menu bar draws them). The floating preview:
# preview, preview-hover, preview-stack (three, the newest with "+1"), preview-motion (key
# frames of its springs), plus popover-macos-mode, settings-capture-macos-mode and
# popover-preview-offer (the one-time offer after an update with the macOS thumbnail on).
# The popover pictures show the strip of earlier screenshots under the latest card;
# popover-undo is the popover just after Move to Trash, with its Undo row.
# Copy what you need into docs/screenshots.
#
# Everything is demo data: a throwaway screenshot folder under the temporary directory,
# an in-memory com.apple.screencapture and a pasteboard that never reaches the system.
# The preferences are passed as launch arguments. The harness reads them from the
# argument domain and keeps every write in memory, so the result does not depend on, and
# does not change, whatever the Debug build (sk.moravcik.ClipShot.debug) last had set.
set -euo pipefail
cd "$(dirname "$0")/.."

LANG_CODE="${1:-en}"
case "$LANG_CODE" in
    en) LOCALE="en_US" ;;
    sk) LOCALE="sk_SK" ;;
    cs) LOCALE="cs_CZ" ;;
    de) LOCALE="de_DE" ;;
    es) LOCALE="es_ES" ;;
    fr) LOCALE="fr_FR" ;;
    *) echo "unknown language: $LANG_CODE (en sk cs de es fr)" >&2; exit 2 ;;
esac
OUT="$PWD/build/screenshots/$LANG_CODE"
DERIVED="build/screenshots-dd"
APP="$DERIVED/Build/Products/Debug/ClipShot.app"

xcodegen generate >/dev/null
xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build

# The locale matches the language, so sizes and relative times are formatted as a user of
# that language sees them. The Debug build is instrumented for coverage; its profile goes
# into the build folder instead of the repository root.
CLIPSHOT_SCREENSHOTS="$OUT" LLVM_PROFILE_FILE="$PWD/$DERIVED/screenshots.profraw" \
    "$APP/Contents/MacOS/ClipShot" \
    -AppleLanguages "($LANG_CODE)" \
    -AppleLocale "$LOCALE" \
    -clipshot.copyEnabled YES \
    -clipshot.copySound NO \
    -clipshot.markupTipShown YES \
    -clipshot.launchAtLoginIntent YES
