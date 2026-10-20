# Development

How ClipShot works inside, how to build and release it, and the findings behind
the rules the code follows. For what the app does, see the [README](README.md).
The design and its amendments are in
[docs/superpowers/specs](docs/superpowers/specs/2026-10-19-clipshot-design.md);
the platform spike that settled the facts below is
[docs/spike-2026-10-19.md](docs/spike-2026-10-19.md).

## What counts as a screenshot

Names are localised and anyone can call a file "Screenshot", so a name is never
evidence. A file is a screenshot when all of this holds:

- a regular file, directly in the screenshot folder (never a subfolder);
- extension `png`, `jpg`, `jpeg`, `heic`, `tiff`, `tif` or `pdf`; never `.mov`;
- the extended attributes macOS writes on a capture:
  `com.apple.metadata:kMDItemIsScreenCapture` true **and**
  `kMDItemScreenCaptureType` present;
- no `com.apple.quarantine` and no `kMDItemWhereFroms`: a downloaded file that
  carries a copied marker is not a local screenshot.

The spike found both attributes on every format and capture mode that saves a
file (F1). Screen recordings carry `kMDItemIsScreenRecording` instead (F9), so
requiring `kMDItemIsScreenCapture` excludes them by itself; the extension filter
stays as a second line. `CaptureMarker` is the one place this is decided.

## How a copy happens

macOS writes a screenshot to a dot-file, renames it into place, and sets the
marker attributes 0 to 54 ms *after* the final rename, typically about 2 ms (F4).
The rename fires a directory event; setting the marker fires none (F5). So:

1. A kqueue source on the folder (`DirectoryEventSource`) reports a change.
   FSEvents is not used: in the spike its events arrived seconds to minutes late.
2. The folder is listed again at 30 ms, 80 ms, 250 ms, 1 s and 3 s after each
   event (`CopyCoordinator.rescanOffsets`). The first two exist for instant
   copy; the later ones cover slow writers such as a large TIFF.
3. `CopyDecider` copies a file once, only when it is a screenshot and *fresh*:
   created **and** modified within the last 30 s. A Finder duplicate of an old
   screenshot gets a new creation date but keeps the old modification date and
   the marker, so it is not copied. Files present when watching starts, when the
   folder changes, or while copying is off, are never copied later.
4. The image goes to the pasteboard as PNG data only (`ClipboardWriter`), never
   as a file URL, so chat apps, Mail and browsers paste the picture rather than
   an attachment. Other formats are converted.

Every fresh screenshot is also recorded in the ledger (below), whether copying is
on or not. All folder IO runs off the main actor on one serial queue: the first
access to Desktop, Documents or Downloads blocks the calling thread until the
TCC prompt is answered (F15).

Measured with the coordinator on synthetic captures that follow the spike's write
sequence: file birth to pasteboard p50 36 ms, p95 45 ms. Shortcut to pasteboard
on the installed build has not been measured yet.

### Two displays, one shortcut

⇧⌘3 on two displays writes one file per display about 10 ms apart, main display
first (F3). Copying both would leave the second display on the clipboard, so the
first display capture of a group within 1 s is copied; the rest are recorded and
shown as "+1" on the preview.

## Preview modes

While the macOS floating thumbnail is on screen, the screenshot exists only in
memory: no temporary file anywhere. The file appears when the thumbnail goes away,
about 6 s after the shortcut, against about 150 ms with the thumbnail off (F6,
and measured again for Addendum A of the design). Instant copy and the macOS
thumbnail exclude each other, which is why there is a Preview setting:

- **ClipShot** writes `show-thumbnail = false` and shows ClipShot's own floating
  preview (`UI/FloatingPreview/`): a non-activating panel at `.statusBar` level,
  on every Space and over full-screen apps, placed on the display the capture came
  from (`kMDItemScreenCaptureGlobalRect`, then the display with the pointer, then
  the main one).
- **macOS** leaves the thumbnail on; the copy lands when the file appears.
- **None** turns the thumbnail off and shows nothing.

The setting mirrors the system: with `show-thumbnail` on, ClipShot reads the mode
as macOS and never turns it back off by itself. The default (ClipShot) is applied
once, when the welcome tour's Start copying first starts watching. An install
from before Preview modes gets a one-time offer in the popover instead of a silent
change.

### Markup

A click on a preview or a popover picture opens the system Markup extension
(`com.apple.MarkupUI.Markup`) through `NSSharingService`. The Quick Look panel has
no public editing API and was ruled out in the spike (F-markup). If the extension
is unavailable, Preview.app opens the file.

The file opened for editing gets an `EditSession`: for 30 minutes, or until the
editor closes plus 5 s, it is exempt from the "created within 30 s" rule (not from
"modified within 30 s"), so a long edit still lands on the clipboard. If Done
returns an edited copy instead of saving in place, that copy goes to the
clipboard and the original file is left alone. A save that replaces the file
keeps it in the ledger (`ScreenshotLedger.followEdit`).

### Motion

Every animation has a job (confirm the copy, show where a screenshot went,
connect two states), uses springs, and settles within about 0.45 s. The tokens
live in `Design.Motion`. With Reduce Motion every transition is an opacity
crossfade. The menu bar "copied" flash is driven by a timer, because a
`MenuBarExtra` label is rendered to a static image and symbol effects never run
there.

## The ledger and retention

`~/Library/Application Support/ClipShot/ledger.json` (0600) lists every fresh
screenshot ClipShot observed: path, file resource identifier, creation date and
size. Retention only ever moves ledger entries, and before each move checks again
that the file is still in the ledger, still the same file (resource identifier),
still a screenshot and still expired.

- Screenshots from before ClipShot, or taken while it was not running, are not in
  the ledger. "Also clean up N older screenshots" adds exactly the files its
  preview counted, and only those still unchanged.
- A renamed screenshot has another path, so it leaves the ledger: renaming keeps
  a screenshot (F17: a rename keeps the marker and the birth time, so the path is
  what tells).
- Entries whose file is gone are pruned.

Retention runs at launch, every hour and after wake, one run at a time, at most
500 files per run. It only runs on a folder the user confirmed with a preview.
`FolderGuard` refuses, after resolving symlinks, the home folder and its
ancestors, `~/Library`, system locations and volume roots, and any folder whose
volume has no Trash. Files go through `FileManager.trashItem` only.

## Native settings

ClipShot writes `com.apple.screencapture` with CFPreferences (`location`,
`location-screenshot`, `show-thumbnail`, and `target` for the destination guard).
Rules from the spike:

- `screencaptureui` caches the preferences while it runs and exits about 5 to 6 s
  after a capture. A change applies to the next capture once it is gone.
  ClipShot never kills it or SystemUIServer: `killall screencaptureui` can lose a
  pending screenshot (F10).
- ⇧⌘5 > Options can write tilde paths (F12). Paths are expanded and standardised
  before they are compared or watched.
- A missing folder makes macOS fall back to the Desktop (F14); ClipShot follows
  and raises an attention row.
- Before its first write, ClipShot backs up the keys it touches to
  `prefs-backup.plist`. Restore deletes keys the backup did not have, because
  `defaults import` only merges (F16).

The folder picker accepts only an existing, writable directory outside app
bundles and system locations.

## The menu bar icon

Template SF Symbols with a distinct shape per state, in a fixed 22 x 16 pt frame
so the status item never changes width and the menu bar never scales it down:

| | |
|---|---|
| `camera.viewfinder` | Copying on. |
| `checkmark.circle` | A copy just landed; it crossfades in and out over 1.5 s (a plain 1.4 s hold with Reduce Motion). |
| `pause.rectangle` | Copying is off. |
| `exclamationmark.triangle` | Something needs fixing. |

`scripts/screenshots.sh` renders every state and every flash phase
(`menubar-states.png`), and the optical size next to VibeRes and Eject Guard
(`menubar-optical-size.png`).

## Languages

English, Slovak, Czech, German, Spanish and French, in String Catalogs
(`ClipShot/Resources/Localizable.xcstrings`, and `InfoPlist.xcstrings` for the
folder access prompts). The English text is the key, defined once in
`UI/Copy.swift`. Conventions and review status are in
[docs/translations.md](docs/translations.md):

| Language | Status |
|---|---|
| en | Source |
| sk, cs, de | Written for the app; reviewed by the author before release |
| es, fr | Machine-assisted; waiting for a native reader |

`make l10n` builds the app and fails when a language misses a key, a plural
misses a CLDR category of its language, a value is empty or not translated, or
the code uses a string the catalog lacks. Log lines stay in English.

## Updates

The app updates itself through [Sparkle](https://sparkle-project.org) 2.10.0,
pinned exactly in `project.yml`. The feed is `appcast.xml` on `main`, served by
raw.githubusercontent.com; archives are GitHub release assets.

- **The running copy must carry our Developer ID signature.** An ad-hoc build
  (`make app`) never contacts the feed. `UpdaterGate` decides this as a pure,
  tested function. A copy installed by the Homebrew cask is not updated by
  Sparkle either: Homebrew owns it, and Settings > About says so.
- **The archive and the feed must carry our EdDSA signature.** The public key is
  `SUPublicEDKey` in Info.plist, and `SURequireSignedFeed` makes clients refuse an
  unsigned feed.
- **The repository has to be public.** Sparkle has no GitHub credentials; on a
  private repository the feed and the asset answer 404 and every check fails
  quietly. `scripts/release.sh` refuses to start otherwise.

Sparkle normally installs on quit, which for a menu bar app can mean never, so the
popover offers a row to restart into a downloaded update.

### Shared EdDSA key: accepted risk

ClipShot, VibeRes and Eject Guard sign updates with the same EdDSA key. The
private key is in the login keychain of the release Mac and backed up; it never
leaves it. This is an accepted risk, chosen on purpose: one key to guard and back
up instead of three.

What the key protects, read from Sparkle 2.10.0's source
(`build/SourcePackages/checkouts/Sparkle` after a build):

- With `SUVerifyUpdateBeforeExtraction` on, the archive is checked against the
  EdDSA key before it is unpacked (`Sparkle/SUUpdateValidator.m` 60-75). After
  unpacking, the new app only has to pass Sparkle's basic policy and carry *a*
  valid Apple code signature (lines 170-206); it is not compared with the
  installed app's signature. Matching the two is only a fallback for when the
  EdDSA check fails (lines 360-375: either one passing is enough).
- Which bundle inside the archive is installed is picked by name (`ClipShot.app`)
  or by bundle identifier (`Autoupdate/SUInstaller.m` 81-110). A package in the
  archive can be used too (lines 92-121).

So the honest exposure is this: **anyone holding the shared private key can sign
an archive with a bundle named ClipShot.app, or with ClipShot's bundle
identifier, and every installed copy will install it**, the same for VibeRes and
Eject Guard. A genuine VibeRes archive is not installed as ClipShot only because
its bundle has the wrong name and identifier, not because of any signature
check. Serving such an archive also needs control of the feed, which is signed
with the same key. The key is the whole defence, which is why it stays in one
keychain with an offline backup. Losing it would strand existing installs of all
three on their current version.

### Releasing

Releases run locally; nothing depends on CI.

```sh
# bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in project.yml,
# write release-notes/<version>.md, commit both on main and push
make signed-app-dry     # optional: sign and verify only, no Apple round trip
scripts/release.sh
```

`scripts/release.sh` in order:

1. Preflight: on `main`, clean tree, same commit as `origin/main`, tag and
   release absent, notes present, repository public, tap working copy clean,
   `CURRENT_PROJECT_VERSION` above the highest `sparkle:version` already in
   `appcast.xml` (Sparkle offers an update only for a higher build number),
   `make test l10n guards`, the notarytool profile works. An inherited
   `SKIP_NOTARIZE` is cleared.
2. `scripts/release-signed.sh`: Release build with the Developer ID identity,
   Sparkle's nested helpers re-signed, every signable item checked for Developer
   ID, hardened runtime, timestamp and no debug entitlements, universal binary,
   notarized, stapled, zipped to `artifacts/ClipShot-<version>.zip`.
3. Verify what will be published: `lipo -archs` is `x86_64 arm64`, no
   `get-task-allow`, `spctl -a -vv` says Notarized Developer ID and `stapler
   validate` passes, for the built app and the app inside the ZIP.
4. Rehearse the appcast on the local ZIP into a temporary feed, with both
   signatures verified. Any appcast or key problem, and the keychain prompt,
   comes up here, while nothing is public.
5. Commit "Release X" (empty), tag `vX`, push both atomically.
6. `gh release create` with the ZIP and the notes file.
7. Download the asset back from GitHub and compare it byte for byte with the
   local ZIP, build the appcast from those bytes (`scripts/make-appcast.sh`
   signs the feed and verifies the enclosure signature and the feed signature),
   commit and push `appcast.xml`.
8. Fetch the feed and the asset as a client would: verify the feed's own
   signature, and check the length and the enclosure signature against the
   asset.
9. Update version and sha256 in the tap's cask (`~/Projects/homebrew-clipshot`),
   `brew audit --cask --strict --online`, `brew style`, push.

It is interactive: `sign_update` asks for access to the EdDSA key in the
keychain (set `SPARKLE_EDDSA_PRIVATE_KEY_PATH` to use a key file instead). Nothing
public is rolled back. If the push of the tag fails, the script prints the two
commands that undo the local commit and tag. If a step after the tag fails, it
says what is already public and how to finish:

```sh
scripts/release.sh --resume-from appcast
```

That mode skips the build, the tag and the GitHub release. It requires the tag
on origin and the release with its asset, downloads the asset again, and
continues from step 7 (when the local ZIP is still there, the download is
compared with it). The other preflight checks still run, except the tests, the
notarytool check and the build-number check against the feed, which may already
hold this release.

`release-notes/<version>.md` is both the GitHub release body and the text in
Sparkle's update window (converted to HTML; paragraphs, `- ` bullets and
backtick code). There is no hand-edited changelog.

`.release.env` (gitignored) holds the notarytool profile name only:
`NOTARY_PROFILE="viberes-notary"`, the profile the sibling apps use.

## Layout

```
ClipShot/Core/      no SwiftUI: capture marker, copy pipeline, ledger, retention,
                    folder guard, screencapture prefs and backup, log
ClipShot/UI/        the app model, popover, floating preview, Settings, tour,
                    Markup, updater
ClipShot/Preview/   Debug only: the screenshot harness and its demo data
ClipShot/Resources/ String Catalogs
ClipShot/AppIcon.icon   Icon Composer document
ClipShotTests/      Swift Testing suites; fixtures from the spike and for l10n
scripts/            release, appcast, screenshots, guards, l10n, spike probes
docs/               spike, translations, README pictures, design and plan
release-notes/      one file per version
Casks/              reference copy of the Homebrew cask
```

Swift 6 language mode, strict concurrency complete, warnings as errors, Debug and
Release. `project.yml` is the source of truth; `ClipShot.xcodeproj` is generated
by XcodeGen and not committed. The only dependency is Sparkle.

## Tests

```sh
make test
```

Swift Testing. Pure logic is tested; views are not, except their layout rules. The ones worth knowing about:

| Area | Why it is tested |
|---|---|
| `CopyDeciderTests` | Freshness is created **and** modified within 30 s; a Finder duplicate of an old screenshot is never copied; one copy per file. |
| `CopyCoordinatorTests`, `InstantCopyTests` | The rescan schedule catches a marker set after the rename; files present at start are never copied; the second display of a capture is not copied; birth to pasteboard stays fast. |
| `CaptureMarkerTests` | The screenshot definition above, on files written with the attributes macOS sets; recordings and downloaded files are refused. |
| `RetentionScannerTests`, `RetentionRunnerTests`, `FolderGuardTests` | Only ledger files move, revalidated just before the move; broad and system folders are refused after resolving symlinks; future dates and unmarked files are skipped; at most 500 per run. |
| `ScreenshotLedgerTests` | Renamed files leave; edits keep their entry; gone files are pruned. |
| `PrefsBackupTests` | Restore removes keys the backup did not have (F16). |
| `PreviewModeTests`, `EditSessionTests`, `TrashTests` | The mode follows the system thumbnail; the Markup exemption; only ledger files in the watched folder go to the Trash, and Undo puts them back. |
| `UpdaterGateTests`, `SparkleConfigurationTests` | Ad-hoc and Homebrew copies never self-update; the feed and key are what releases expect. |
| `LocalisationTests` | The l10n gate fails on the broken catalogs in `ClipShotTests/Fixtures/l10n`. |
| `StatusIconStateTests`, `PopoverLayoutTests` | The menu bar label is never scaled and fits its frame; the popover's bottom soft scroll edge. |

Tests never touch real preferences (`make guards` refuses `UserDefaults` in
tests) and use temporary folders.

## Safety notes

- Nothing under `ClipShot/` calls `removeItem` or `unlink`; `make guards`
  enforces it. User files only ever go through `FileManager.trashItem`.
- The app is not sandboxed: it reads and writes `com.apple.screencapture` and
  watches any folder the user picks.
- Folder access (TCC) for Desktop, Documents, Downloads, removable and network
  volumes is declared with usage strings. The folder is not touched before the
  tour's second step has explained why, or the tour was skipped.
- The log (`~/Library/Logs/clipshot.log`, 0600) is in English and records counts
  and file extensions, never names or paths. At 512 KB it rolls to `.log.1` by
  rename. "Report" opens a pre-filled GitHub issue with the macOS and app versions
  and the last log lines, so the no-paths rule matters.
- The ledger is 0600 and replaced atomically by rename.

## Build

```sh
brew install xcodegen
make app             # Release, ad-hoc signed
make test
make l10n
make guards
make signed-app-dry  # Developer ID signature and checks, no notarization
make signed-app      # signed, notarized, stapled, zipped to artifacts/
```

`make app` turns the hardened runtime off: with an ad-hoc signature, library
validation would refuse the Developer ID-signed Sparkle.framework. Signed builds
keep it on. An ad-hoc signature is identified by its code directory hash, so after
each rebuild macOS asks for folder access again; a Developer ID build keeps the
grant.

### The app icon

`ClipShot/AppIcon.icon` is an Icon Composer document and the source of truth.
Xcode compiles it into `Assets.car` and `AppIcon.icns` during the build
(`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`).

### Signing and notarization

`scripts/release-signed.sh` needs a "Developer ID Application" certificate in the
keychain and a notarytool keychain profile (`NOTARY_PROFILE` in `.release.env`).
`SKIP_NOTARIZE=1` (what `make signed-app-dry` sets) stops after the signature
checks, to confirm the certificate resolves before spending a submission.

### Reviewing the UI

A `MenuBarExtra` popover cannot be opened programmatically, so a Debug-only
harness renders the real views on demo data:

```sh
scripts/screenshots.sh          # English, into build/screenshots/en
scripts/screenshots.sh sk       # one language
scripts/screenshots.sh all      # all six, one build
scripts/readme-screenshots.sh   # render English and copy the README set into docs/screenshots
```

It renders the popover in every state, every attention row, every Settings tab,
every tour step, the floating preview and its motion as key frames, the menu bar
states, the icon, and the hero and the 1920x1080 banner, in light and dark.
Everything is demo data in `build/screenshots-scratch`: an in-memory
`com.apple.screencapture`, a pasteboard that never reaches the system, a Trash
that refuses every move. Nothing on the Mac that renders is read or changed. The
Debug build is coverage-instrumented; its profile goes into `build/`.

It also checks, in every language, that Settings > Capture with the destination
guard keeps at least the Form's standard 20 pt under its last section, and fails
the run when it does not; that is how Restore was kept from scrolling out of view
in German.

Off-screen, the popover's material has nothing to blur, so it is drawn as a solid
fill and the bottom soft scroll edge is left out. `CLIPSHOT_SCREENSHOTS_LIVE=1`
takes the popover pictures from a window on screen through ScreenCaptureKit
instead, over a demo desktop. That needs Screen Recording for the Debug build,
granted by hand; the harness never asks for it and stops with a message when it
is missing.

The README video of the real flow (shortcut, preview, paste) is recorded by hand.
