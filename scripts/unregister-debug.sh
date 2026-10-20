#!/usr/bin/env bash
#
# Unregisters a Debug ClipShot.app, and every app inside it (Sparkle's Updater.app), from
# Launch Services. xcodebuild registers what it builds; a Debug build left registered shows
# up as a second ClipShot in the Shortcuts app. Missing apps are skipped; it never fails.
#
#   scripts/unregister-debug.sh PATH/TO/ClipShot.app...

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for app in "$@"; do
  [ -d "$app" ] || continue
  # The app itself first, then everything inside it.
  find "$app" -name '*.app' -type d -print 2>/dev/null | while IFS= read -r each; do
    "$LSREGISTER" -u "$each" >/dev/null 2>&1 || true
  done
done
exit 0
