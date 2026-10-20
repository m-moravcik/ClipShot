#!/bin/bash
# Render the README screenshots, the app icon, the menu bar states and the portfolio
# banner from the app itself. See ClipShot/Preview/ScreenshotHarness.swift.
#
#   scripts/screenshots.sh        # English, into build/screenshots/en
#   scripts/screenshots.sh sk     # Slovak, for the web.pexelo portfolio
#   scripts/screenshots.sh all    # every language, one build; also the margin check below
#
# The README pictures are copied from build/screenshots/en into docs/screenshots by
# scripts/readme-screenshots.sh, so a new menu bar symbol or a UI change is one command away
# from the README.
#
# Measures: "measure:" lines give the popover's content height and its shown height (capped
# at 600 pt) for popover, popover-one, popover-undo, popover-undo-top and popover-full; the
# run fails if a popover is taller than the cap, or if the everyday popover with the Undo
# strip (popover-undo, popover-undo-top) would scroll.
#
# Checks: in every language, Settings > Capture with the destination guard must keep at
# least the Form's standard 20 pt under its last section; the run fails (after writing every
# picture) when it does not. `all` is how the six real languages are checked together.
#
# Writes, in -light and -dark: popover, popover-one, popover-paused, popover-paused-focus
# (paused by a Focus filter), popover-attention,
# popover-full (every row at once, Undo included: past the height cap, so the middle
# scrolls), attention-* (one per
# attention row), settings-{general,capture,retention,about}, settings-general-replayed,
# settings-retention-{cleaned,trash-not-opened,nothing-moved} (just after Clean up now),
# onboarding-3-tidy-fresh (step 3 on a fresh install, offering the older screenshots),
# settings-retention-older (the offer for screenshots from before ClipShot ran),
# settings-capture-attention (the destination guard), onboarding-* (every tour step, and
# Try it blocked by an attention), hero (popover under the menu bar, README) and banner
# (1920x1080). Plus icon.png, menubar-states.png, menubar-moments.png (every frame of Peg's
# moments) with peg-frames/ (one PNG per frame, for GIFs) and menubar-optical-size.png (the
# states beside VibeRes and Eject Guard, sized as the menu bar draws them). The floating preview:
# preview, preview-hover, preview-stack (three, the newest with "+1"), preview-motion (key
# frames of its springs, the swipe tipping past the dismiss point, hover and a drag in hand), plus popover-macos-mode, settings-capture-macos-mode and
# popover-preview-offer (the one-time offer after an update with the macOS thumbnail on).
# The popover pictures show the list of the four most recent screenshots, the current one
# on top; popover-one has a single row (the first screenshot), popover-recent-hover the
# pointer over the second row's picture (its pencil), popover-pill-hover the pointer on the
# second row's Copy pill;
# popover-undo is the popover just after Move to Trash on the second row, the Undo strip in
# that row's place, popover-undo-top the same for the screenshot just taken (as from its
# floating preview), and popover-note the note above the list saying why a Move to Trash
# did not happen; preview-undo is a preview that
# moved its screenshot to the Trash (Undo on the preview) above one whose move failed,
# saying why on the preview. Popover and tour
# pictures carry the window's rounded corners and shadow on a transparent margin.
#
# CLIPSHOT_SCREENSHOTS_LIVE=1 takes the popover pictures from a window on screen through
# ScreenCaptureKit, so the material and the bottom soft scroll edge are the real ones. It needs
# Screen Recording for the Debug build, granted by hand once; the harness never asks for it
# and stops with a message when it is missing. Off by default.
#
# Everything is demo data: a throwaway screenshot folder under build/screenshots-scratch,
# an in-memory com.apple.screencapture and a pasteboard that never reaches the system.
# The preferences are passed as launch arguments. The harness reads them from the
# argument domain and keeps every write in memory, so the result does not depend on, and
# does not change, whatever the Debug build (sk.moravcik.ClipShot.debug) last had set.
set -euo pipefail
cd "$(dirname "$0")/.."

LANG_ARG="${1:-en}"
case "$LANG_ARG" in
    all) LANGS=(en sk cs de es fr) ;;
    en|sk|cs|de|es|fr) LANGS=("$LANG_ARG") ;;
    *) echo "unknown language: $LANG_ARG (en sk cs de es fr, or all)" >&2; exit 2 ;;
esac
DERIVED="build/screenshots-dd"
APP="$DERIVED/Build/Products/Debug/ClipShot.app"

xcodegen generate >/dev/null
xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build
# Icon Services caches an app's icon per bundle and keeps handing the old one to
# NSWorkspace.icon(forFile:) and applicationIconImage after the icon changes, until the
# bundle is registered again. Without this, icon.png and the tour kept the previous icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

failed=()
for LANG_CODE in "${LANGS[@]}"; do
    # The locale matches the language, so sizes, times and relative dates are formatted as a
    # user of that language sees them. The clock is set too, not inherited from this Mac:
    # English on 12 hours (9:12 AM), the others on 24.
    case "$LANG_CODE" in
        en) LOCALE="en_US"; HOURS24=NO ;;
        sk) LOCALE="sk_SK"; HOURS24=YES ;;
        cs) LOCALE="cs_CZ"; HOURS24=YES ;;
        de) LOCALE="de_DE"; HOURS24=YES ;;
        es) LOCALE="es_ES"; HOURS24=YES ;;
        fr) LOCALE="fr_FR"; HOURS24=YES ;;
    esac
    OUT="$PWD/build/screenshots/$LANG_CODE"
    # The demo folders of the previous run go to the Trash (never rm); the harness makes new
    # ones here, inside the gitignored build folder.
    SCRATCH="$PWD/build/screenshots-scratch/$LANG_CODE"
    if [ -e "$SCRATCH" ]; then
        /usr/bin/trash "$SCRATCH" >/dev/null
    fi
    mkdir -p "$SCRATCH"

    # The Debug build is instrumented for coverage; its profile goes into the build folder
    # instead of the repository root.
    if ! CLIPSHOT_SCREENSHOTS="$OUT" CLIPSHOT_SCREENSHOTS_SCRATCH="$SCRATCH" \
        LLVM_PROFILE_FILE="$PWD/$DERIVED/screenshots.profraw" \
        "$APP/Contents/MacOS/ClipShot" \
        -AppleLanguages "($LANG_CODE)" \
        -AppleLocale "$LOCALE" \
        -AppleICUForce24HourTime "$HOURS24" \
        -clipshot.copyEnabled YES \
        -clipshot.markupTipShown YES \
        -clipshot.launchAtLoginIntent YES; then
        failed+=("$LANG_CODE")
    fi
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo "screenshots: failed for ${failed[*]}" >&2
    exit 1
fi
