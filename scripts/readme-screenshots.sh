#!/bin/bash
# Re-render the README pictures and copy them into docs/screenshots, in one step.
#
#   scripts/readme-screenshots.sh
#
# Renders English with scripts/screenshots.sh (pass CLIPSHOT_SCREENSHOTS_LIVE=1 through the
# environment for the live popover capture), then copies the README set over the files in
# docs/screenshots. The README links these names, so after a UI change, or a new menu bar
# symbol, this is the whole refresh: run it, look at the diff, commit. The README's animated
# hero (docs/hero.gif, docs/hero-dark.gif) comes from scripts/readme-hero.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/screenshots.sh en

SRC="build/screenshots/en"
DEST="docs/screenshots"

# Light and dark of each.
PAIRS=(
    popover
    popover-paused-focus
    preview-hover
    popover-undo
    settings-capture
    settings-retention
)
for name in "${PAIRS[@]}"; do
    for scheme in light dark; do
        cp "$SRC/$name-$scheme.png" "$DEST/$name-$scheme.png"
    done
done
cp "$SRC/icon.png" "$DEST/icon.png"

echo "docs/screenshots refreshed from $SRC; check the README against them before committing."
