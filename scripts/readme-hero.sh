#!/bin/bash
# Render the README's hero animation: hero.gif, hero.mp4, poster.png and a contact sheet.
#
#   scripts/readme-hero.sh                       # light and dark, then docs/hero.gif and docs/hero-dark.gif
#   scripts/readme-hero.sh light|dark [out-dir]  # one appearance, into out-dir only
#
# Output per appearance: build/readme-hero/<appearance>/ (or out-dir). See
# ClipShot/Preview/ReadmeHero.swift: the real views and Peg's own drawing on a demo desktop,
# rendered frame by frame off screen at 30 fps and 1920 x 1280 px, then downscaled to
# 960 x 640 (lanczos). Only the GIFs go into the repository; the MP4s and posters are for the
# web and stay in the build folder. Nothing is captured from the screen, and nothing reads or
# changes this Mac's screenshot settings, folder, clipboard or preferences. Needs ffmpeg.
# DERIVED overrides the derived data path.
set -euo pipefail
cd "$(dirname "$0")/.."

ARG="${1:-all}"
case "$ARG" in
    all) SCHEMES=(light dark) ;;
    light|dark) SCHEMES=("$ARG") ;;
    *) echo "unknown appearance: $ARG (light, dark, or nothing for both)" >&2; exit 2 ;;
esac
DERIVED="${DERIVED:-build/readme-hero-dd}"
APP="$DERIVED/Build/Products/Debug/ClipShot.app"
FPS=30
WIDTH=960
# A GitHub README shows GIFs up to 10 MB; this keeps them comfortable to load.
MAX_GIF_BYTES=$((5 * 1024 * 1024))

# xcodebuild registers the Debug build with LaunchServices. Unregistered on exit, so this
# Mac's Shortcuts app never lists the Debug build's actions as a second ClipShot. Only this
# build folder's app, never /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_debug() {
    case "$APP" in /*) "$LSREGISTER" -u "$APP" ;; *) "$LSREGISTER" -u "$PWD/$APP" ;; esac >/dev/null 2>&1 || true
}
trap unregister_debug EXIT

xcodegen generate >/dev/null
xcodebuild -project ClipShot.xcodeproj -scheme ClipShot -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO -quiet build

PROFILE_DIR="$(cd "$DERIVED" && pwd)"
for SCHEME in "${SCHEMES[@]}"; do
    if [ "$ARG" = all ]; then
        OUT="build/readme-hero/$SCHEME"
    else
        OUT="${2:-build/readme-hero/$SCHEME}"
    fi
    mkdir -p "$OUT"
    OUT="$(cd "$OUT" && pwd)"
    # The previous run's frames go to the Trash (never rm).
    if [ -e "$OUT/frames" ]; then
        osascript -e "tell application \"Finder\" to delete POSIX file \"$OUT/frames\"" >/dev/null
    fi

    CLIPSHOT_README_HERO="$OUT" CLIPSHOT_README_HERO_SCHEME="$SCHEME" \
        LLVM_PROFILE_FILE="$PROFILE_DIR/hero.profraw" \
        "$APP/Contents/MacOS/ClipShot" \
        -AppleLanguages "(en)" \
        -AppleLocale "en_US"

    SCALE="scale=$WIDTH:-2:flags=lanczos"
    ffmpeg -v error -y -framerate $FPS -i "$OUT/frames/%04d.png" \
        -vf "$SCALE,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
        -loop 0 "$OUT/hero.gif"
    ffmpeg -v error -y -framerate $FPS -i "$OUT/frames/%04d.png" \
        -vf "$SCALE" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart "$OUT/hero.mp4"
    ffmpeg -v error -y -i "$OUT/frames/0000.png" -vf "$SCALE" "$OUT/poster.png"
    # Six key frames: calm start, the selection, the arrival, Peg pegged with its check, pasted, the preview leaving.
    SHEET_FRAMES=(0 45 63 125 140 213)
    INPUTS=()
    for f in "${SHEET_FRAMES[@]}"; do INPUTS+=(-i "$OUT/frames/$(printf %04d "$f").png"); done
    ffmpeg -v error -y "${INPUTS[@]}" -filter_complex \
        "[0]scale=640:-2:flags=lanczos[a];[1]scale=640:-2:flags=lanczos[b];[2]scale=640:-2:flags=lanczos[c];[3]scale=640:-2:flags=lanczos[d];[4]scale=640:-2:flags=lanczos[e];[5]scale=640:-2:flags=lanczos[f];[a][b][c][d][e][f]xstack=inputs=6:layout=0_0|w0_0|w0+w1_0|0_h0|w0_h0|w0+w1_h0" \
        "$OUT/_sheet.png"

    size=$(stat -f %z "$OUT/hero.gif")
    if [ "$size" -gt "$MAX_GIF_BYTES" ]; then
        echo "hero.gif ($SCHEME) is $size bytes, over $MAX_GIF_BYTES" >&2
        exit 1
    fi
    ls -l "$OUT"/hero.gif "$OUT"/hero.mp4 "$OUT"/poster.png "$OUT"/_sheet.png

    if [ "$ARG" = all ]; then
        case "$SCHEME" in
            light) cp "$OUT/hero.gif" docs/hero.gif ;;
            dark) cp "$OUT/hero.gif" docs/hero-dark.gif ;;
        esac
    fi
done

if [ "$ARG" = all ]; then
    echo "docs/hero.gif and docs/hero-dark.gif refreshed; look at both before committing."
fi
