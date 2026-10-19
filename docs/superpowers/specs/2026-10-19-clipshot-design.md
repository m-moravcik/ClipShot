# ClipShot - design

**Status:** approved 2026-10-19, revised the same day after plan verification, AI audit and motion review (safety and UX additions, no scope change); not implemented
**Date:** 2026-10-19
**Owner:** Michal Moravčík (`m-moravcik`)

## Intent

macOS can save a screenshot as a file *or* put it on the clipboard, never both,
and it shows the floating thumbnail only when it saves a file. Michal wants all
three for every capture: the native thumbnail, the saved file, and the image on
the clipboard ready to paste. He also wants old screenshots to stop piling up.

Today this runs as a personal launchd agent
(a launchd copier script:
a zsh script that copies the newest PNG
in the screenshot folder with `osascript ... «class PNGf»`). It works, verified
2026-10-19. ClipShot turns that into a proper public menu bar app in the same
family as VibeRes and Eject Guard, with settings for the things we had to
change by hand with `defaults write com.apple.screencapture`, plus retention.

ClipShot keeps the native shortcuts (`Cmd+Shift+3/4/5`) and the native capture
UI. It does not capture anything itself.

## Goals

1. **Copy every saved screenshot to the clipboard**, automatically, while macOS
   still saves the file and shows the thumbnail.
2. **Settings for native screenshot behaviour** without Terminal:
   save folder, floating thumbnail on/off. ClipShot also detects when the
   native destination is set to Clipboard (which disables files and the
   thumbnail, so ClipShot cannot work) and offers a one-click fix.
3. **Retention**: move screenshots older than N days to the Trash.
4. **Feels like Michal's other apps**: same design tokens, popover, settings
   window, onboarding, icon style, README, release and update path.
5. **Full public release cycle**: public repo, signed and notarized build,
   Sparkle updates, Homebrew cask, GitHub profile entry, portfolio reference on
   web.pexelo.com.

## Non-goals (v1)

- Own capture engine, annotation, OCR, cloud upload, scrolling capture.
- Changing file format, shadow, filename prefix or other `screencapture` keys
  beyond folder, thumbnail and target. Candidates for later.
- Anything for screen recordings (`.mov`): no clipboard copy, no retention.
  Michal: "may be nice in a next version, not needed in the first". Tracked
  as a GitHub issue for v1.1+.
- Own editor. Annotation stays native: clicking the floating thumbnail opens
  macOS Markup (draw, text, shapes, crop).
- CLI companion, Shortcuts/App Intents.
- Mac App Store, sandbox.

## Anti-goals (failure even if it "works")

- **Trashing a file that is not a macOS screenshot**, or any file outside the
  screenshot folder. Retention must be impossible to point at someone's
  Documents by accident.
- **Permanent deletion.** Retention only ever moves to the Trash.
- Overwriting the clipboard with something old (an existing file touched,
  renamed or moved into the folder).
- Breaking or replacing the native shortcuts.
- Nagging for permissions, or silently failing without telling the user why.

## Constraints

- Not sandboxed (needs to read and write `com.apple.screencapture` prefs and
  watch arbitrary folders), like the sibling apps.
- macOS shows the file only after the thumbnail is dismissed (about 5 s, or
  immediately when swiped away). The clipboard copy therefore lands at that
  moment, not at capture time. This is a platform limit; document it in README
  and onboarding, don't try to work around it.
- If the user picks Desktop, Documents, Downloads or an iCloud folder as the
  save folder, macOS asks for folder access (TCC). Ask lazily, explain in
  app-authored copy, fall back to a clear in-popover warning on denial.
- Michal's rule: GitHub Actions never run on his accounts. All checks, builds
  and releases run locally. A `.github/workflows/ci.yml` may exist for
  others' forks, but the release must not depend on it.
- Michal's rule: the review gate's pipeline is the
  required review.

## Decisions

### Decided by Michal

- Name **ClipShot**. Repo `m-moravcik/ClipShot`, public. A tiny unrelated
  `3ricpeng/clipshot` script exists (0 stars, no licence); accepted.
- Menu bar app in the VibeRes / Eject Guard family, visually one family.
- Menu bar icon and a proper app logo.
- Settings: save folder, thumbnail, clipboard copy, retention.
- Full release cycle (repo, release, GitHub profile, web.pexelo.com portfolio).

### Builder's calls already made (Michal can veto while reading)

- **Platform:** Swift 6, strict concurrency complete, warnings as errors,
  SwiftUI `MenuBarExtra(.window)` + small AppKit. `LSUIElement`. Universal
  binary. **Minimum macOS 26**, like VibeRes. The only test machine runs
  macOS 27.0.1, and the README and cask must not claim support nobody has
  tested. Lowering it later is a separate decision that needs a 14/15 test
  machine or VM. App icon from Icon Composer (Assets.car).
- **Project:** XcodeGen `project.yml` + Makefile, like VibeRes (newer, String
  Catalog, Xcode-built assets). `Core/` without SwiftUI, shared with tests.
  Swift Testing. Pure logic tested, views not.
- **Identity:** display name ClipShot, bundle id `sk.moravcik.ClipShot`,
  Debug `sk.moravcik.ClipShot.debug`, executable `ClipShot`, support folder
  `~/Library/Application Support/ClipShot/`, log
  `~/Library/Logs/clipshot.log` (0600, rolls at 512 KB, English).
- **Languages:** en, sk, cs, de, es, fr (es and fr requested by Michal
  2026-10-19; the same set is being added to VibeRes and Eject Guard).
- **Version:** first public release **1.0.0** (feature complete, not a beta).
- **Updates:** Sparkle 2.10.0 pinned, same EdDSA key as the siblings, feed
  `https://raw.githubusercontent.com/m-moravcik/ClipShot/main/appcast.xml`,
  daily check, `UpdaterGate` (ad-hoc builds never self-update), in-popover
  "update ready" row.
- **Distribution:** Developer ID, hardened runtime, notarized (`notarytool`
  keychain profile in gitignored `.release.env`), stapled. GitHub Release
  asset `ClipShot-<version>.zip`. Homebrew tap `m-moravcik/homebrew-clipshot`,
  cask `clipshot`, updated by the local release script.
- **Licence:** MIT, "Copyright (c) 2026 Michal Moravčík".

## Behaviour

### Clipboard copy

- Watches the *current* screenshot folder: `com.apple.screencapture`
  `location-screenshot`, else `location`, else `~/Desktop`. Re-reads when the
  pref changes (ClipShot's own setting or the native `Cmd+Shift+5` Options).
- A file qualifies when it is a new image file (png/jpg/heic/tiff/pdf as macOS
  can produce) **and** carries the screen-capture marker macOS writes
  (`com.apple.metadata:kMDItemIsScreenCapture` xattr). Checked 2026-10-19 on
  macOS 27.0.1: a `Cmd+Shift+4` PNG carries `kMDItemIsScreenCapture = 1` and
  `kMDItemScreenCaptureType = "selection"`. The spike confirms it for the
  other formats macOS can be set to (jpg, heic, tiff, pdf) and for full-screen
  and window captures.
- Copies the image to `NSPasteboard.general` as **PNG image data only**
  (`«class PNGf»` / `.png`), the same as the personal script Michal verified
  pasting in his apps. No file URL on the pasteboard: Slack, Mail, Messages
  and browsers would then paste a file attachment instead of an inline image.
  Non-PNG captures are converted to PNG for the pasteboard.
- Never copies the same file twice, never copies a file older than 30 s.
  "Fresh" means both creation and modification time are within 30 s: a Finder
  duplicate of an old screenshot gets a new creation date but keeps the old
  modification date and the marker, and must not be copied. Verified
  2026-10-19: real captures have birth and mtime within about 1 ms.
- Files present when ClipShot starts, when the folder changes, or while
  copying is paused are never copied later.
- If a fresh marked screenshot cannot be copied (decode or pasteboard
  failure), the popover shows an attention row "ClipShot saw a screenshot but
  could not copy it" with a "Report" link that opens a pre-filled GitHub issue
  (macOS version, app version, last log lines, no paths).
- Copying always replaces the clipboard; "Copy again" on the latest card is
  the recovery. (Builder's call.)
- **Markup flow:** when the user clicks the thumbnail, edits in Markup and
  clicks Done, macOS writes the file with the edits, so the clipboard gets
  the annotated image. The spike confirms macOS writes the file once (not
  original then edited); if it writes twice, the later write within the
  window wins. README and onboarding mention this as a feature.
- Toggle: on by default.
- Feedback: the menu bar icon briefly shows a "copied" state (about 1.5 s).
  Optional sound off by default. No notification banners.

### Native settings

- **Save folder:** folder picker, plus "Reset to macOS default". Writes the
  native prefs so `Cmd+Shift+5` Options shows the same folder. Screen
  recordings follow the same folder.
- **Floating thumbnail:** on/off (`show-thumbnail`).
- **Destination guard:** if the native destination (`target` /
  `target-screenshot`) is anything other than file, show a warning row in the
  popover and Settings with a "Fix" button that sets it back to file.
- Changes apply without logout. The builder finds the minimal reliable way
  (we needed `killall SystemUIServer` on 27.0.1).
- The folder picker accepts only an existing, writable directory that is not
  inside an app bundle or a system location.
- Before its first write ClipShot backs up the `com.apple.screencapture` keys
  it touches to `~/Library/Application Support/ClipShot/prefs-backup.plist`;
  Settings offers "Restore previous settings".
- Folder access (TCC): ClipShot declares usage strings for Desktop,
  Documents, Downloads, removable and network volumes, and does not touch
  the folder before onboarding step 2 explains why.

### Retention

- **Off by default** on a fresh install (anti-goal: surprise deletion). The
  onboarding offers to turn it on.
- Period: 7, 14, 30, 60, 90 days or custom; default 30 when enabled.
- **Only screenshots ClipShot saw being made** (Michal, 2026-10-19). ClipShot
  keeps a ledger (`~/Library/Application Support/ClipShot/ledger.json`, 0600)
  of every fresh screenshot it observed while running: path, file resource
  identifier, creation date, size. Retention only ever moves ledger entries.
  Screenshots that existed before ClipShot, or were taken while it was not
  running, are left alone, except through an explicit one-time "Also clean up
  N older screenshots (X MB)" choice with its own preview, which adds them to
  the ledger. A screenshot the user **renamed** is treated as "keep" and
  leaves the ledger. Entries whose file is gone are pruned.
- **Confirmed folder:** enabling retention shows the preview ("N screenshots
  (X MB) would go to the Trash now") and stores the folder it was confirmed
  for. If the screenshot folder later changes (in ClipShot or in the native
  `Cmd+Shift+5` Options), retention pauses and the popover asks to confirm the
  new folder with its own preview. Retention never runs on a folder the user
  has not seen a preview for.
- Refuses system and broad folders after resolving symlinks: `/`, `/Users`,
  the home folder and its ancestors, `~/Library`, `/System`, `/Library`,
  `/Applications`, and volume roots.
- If the folder's volume has no Trash, retention is disabled with an
  attention row; it never falls back to deleting.
- Skips files whose creation date is in the future; one run moves at most 500
  files and reports "N more pending".
- Scope: only the current screenshot folder, non-recursive, only files with
  the screen-capture marker **and** `kMDItemScreenCaptureType`, and without a
  quarantine or "where from" attribute (a downloaded file with a copied
  marker is not a local screenshot). **No filename fallback**: names are localised and
  anyone can name a file "Screenshot". A file without the marker is never
  touched; if the folder holds unmarked files, Settings says how many were
  skipped and why.
- Screen recordings are out of scope for v1 (see Non-goals); the
  retention filter must exclude `.mov` even if it carries the marker.
- Moves to Trash (`FileManager.trashItem`), never deletes.
- Runs at launch, every hour and after wake. Age = file creation date.
- Settings shows a live preview: "12 screenshots (48 MB) would go to the Trash
  now", and a "Clean up now" button that asks for confirmation with the same
  count. The popover shows a one-line summary ("Keeps 30 days - last cleanup
  today 14:00, 3 moved") and the running total "Freed 1.2 GB since install".
- Renaming a screenshot keeps it: retention skips it from then on; README
  and the Settings note say so.
- Logs record counts and extensions, not paths.

### Popover (300 pt, house tokens)

1. Header: app name + state (Copying on / paused / needs attention).
   "Paused" means the Copy to clipboard toggle is off; there is no separate
   pause control.
2. Attention rows when needed, the top one shown plus "+N more": destination
   not file, folder access denied, folder missing, could not copy, retention
   folder changed, no Trash on volume. Each row says what is wrong and its
   button is named for its effect ("Save screenshots to a file", "Choose
   folder…", "Open Privacy Settings").
   Until the first successful copy, the header shows "Paste works once the
   thumbnail disappears".
3. Latest screenshot card: thumbnail, name, age, actions Copy again / Show in
   Finder.
4. Quick toggle row: Copy to clipboard.
5. Retention summary row.
6. Update ready row (Sparkle).
7. Footer native-menu rows: Open Screenshots Folder, Settings…, About, Quit.

### Settings (470x400 TabView, `.formStyle(.grouped)`)

- **General:** launch at login (SMAppService with reconcile), copy to
  clipboard, copy sound, replay welcome tour.
- **Capture:** save folder, floating thumbnail (with the trade-off: off means
  the file, and so the clipboard, is ready instantly), destination guard
  status, Restore previous settings.
- **Retention:** enable, period, preview, skipped-files note, the line "Screen
  recordings are not touched", Clean up now. (No recordings option in v1.)
- **Updates / About:** Sparkle settings, version, 64 pt icon, links, totals
  (screenshots copied, space freed).

### Onboarding (3 steps in the popover, like siblings)

1. Icon + what ClipShot does (file + thumbnail + clipboard).
2. Where screenshots go: explains folder access, then asks for it; "Try it":
   take a screenshot and see the copied state land; thumbnail timing and
   Markup note.
3. Retention offer (off / 30 days, with the live preview) and launch at login.

### Accessibility and motion

- Status item has an accessibility label per state; each copy and each new
  attention is announced to VoiceOver. Sound is never the only signal.
- Motion follows the siblings: quiet 0.18-0.25 s opacity-led transitions,
  the menu bar "copied" flash is timer-driven (labels are static images),
  Reduce Motion keeps crossfades and drops movement.
- After the third copy, a one-time dismissible tip in the popover: "Click the
  thumbnail to annotate with Markup; ClipShot copies the edited image."

### Menu bar icon

SF Symbols, distinct shape per state, drawn as template images:
idle, copied (brief), paused, needs attention. Candidate base symbol
`camera.viewfinder`; final choice from the preview harness render.

### App icon (logo)

Icon Composer `.icon` with SVG layers in the house style (flat glyph on a
gradient, neutral shadow, translucency off). Concept: a selection marquee
(capture corners) over a clipboard. Its own gradient colour so it reads as a
sibling but not a twin (VibeRes indigo-teal, Eject Guard graphite); candidate
warm coral to amber. Rendered by the preview harness for Michal to approve
before release.

## Repo and release cycle

- README in the house form: centered icon, H1, pitch, light/dark `<picture>`
  hero, What it does, Install (Homebrew, Manual), Using it, Retention and
  safety, Troubleshooting (TCC, destination guard), Building from source,
  License + "Built by … / More projects" footer. Buy me a coffee
  (`FUNDING.yml: buy_me_a_coffee: pexelo`).
- README also has a short demo video/GIF of the flow (shortcut, thumbnail,
  paste), a "Why this exists" paragraph, Uninstall section, and the Homebrew
  one-liner right under the hero.
- `DEVELOPMENT.md` for internals. Release notes as `release-notes/<version>.md`
  like Eject Guard, not a hand-edited CHANGELOG.md (Michal's rule: never edit
  CHANGELOG.md by hand). Default GitHub labels. Topics include `macos`,
  `menu-bar`, `screenshot`, `screencapture`, `clipboard`, `swift`.
- Sparkle EdDSA key shared with VibeRes and Eject Guard: accepted risk,
  documented in DEVELOPMENT.md; the private key stays in the login keychain.
- Development happens on a branch; the repo becomes public only after the
  review gate passes, right before the 1.0.0 release.
- Preview/screenshot harness renders README and portfolio images from demo
  data, light and dark, plus a 1920x1080 portfolio banner.
- Release (local): bump version, release notes, `make signed-app`, notarize,
  zip, `gh release create`, sign and commit appcast, push the cask to the tap.
- After 1.0.0 is live:
  - GitHub profile `m-moravcik/m-moravcik` README: add ClipShot to the apps
    list next to VibeRes and Eject Guard.
  - Portfolio: new reference in the portfolio site
    (`src/data/portfolioProjects.ts`, assets `src/assets/clipshot/`) using that
    repo's `portfolio-reference` skill, then its normal deploy.
- Migration for Michal's machine: after installing 1.0.0, unload and trash the
  personal launchd agent and script so two copiers don't race.

## Left to the builder

- Folder watching mechanism (FSEvents / DispatchSource), debounce.
- Exact pref keys to write and how to apply them without logout, per spike.
- Final SF Symbols, icon artwork details, exact gradient values.
- Copy text and translations within the house tone.
- Test layout and which state types to extract for testing.
