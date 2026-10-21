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
  carries a copied marker is not a local screenshot;
- owned by the user ClipShot runs as. On a shared folder (a network volume,
  `/Users/Shared`) anyone can write a file with the marker; another user's file
  is never read, copied, recorded or moved.

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

Each pass costs one `lstat` per file. The marker (four or five `getxattr` calls)
is read only for a file that could be copied: fresh by its times, open in Markup,
or new since the last listing. With 3,000 old screenshots in the folder a pass
takes about 20 ms instead of about 290 ms.

Every read of a screenshot, for the copy, a thumbnail, the preview or a drag,
goes through `FileTrust`: one descriptor opened with `O_NOFOLLOW`, `fstat` says a
regular file owned by this user and at most 256 MB, and ImageIO's reported size
is at most 100 megapixels (a PDF page is checked at the 2x it is rastered at)
before anything is decoded. A refused file is skipped quietly; the log says why,
with the extension only.

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

### At rest

With nothing happening, ClipShot still wakes for three things:

- The coordinator's poll, every 1 s (`CopyCoordinator.start`): it re-reads the
  folder pref (`CaptureSettings.folder()`, two or three
  `CFPreferencesAppSynchronize` calls) and `stat`s the folder. macOS posts
  nothing when ⇧⌘5 > Options or `defaults write` changes the folder (F12 saw the
  change by polling), so this read is what picks a new folder up at once; the
  same read notices a watched folder that was removed or replaced. It stays
  until a notification (kqueue on the prefs file, or a `CFPreferences` one) can
  replace it. A pass runs on the poll only while a file is open in Markup.
- The model's status loop, every 5 s with 20 % tolerance: destination, Preview
  and format prefs, the retention status and whether another app took the
  clipboard. The list of recent screenshots is re-read only while the popover is
  open.
- Retention's hourly timer and the wake notification.

Peg's frame timer runs only while a moment plays. Idle CPU measured over 60 s
with the popover never opened: 0.03 to 0.04 %, far under the 0.1 % target.

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
connect two states, alert, introduce Peg, celebrate the first copy once). In-app
transitions use springs and settle in 200-450 ms. Menu bar moments are the
longer ones: a glyph at the edge of the screen has to be slow enough to catch
at a glance, so the copy animation runs 2.9 s: VibeRes's approved 2.4 s, plus
half a second since the owner saw the two pictures trade places too fast
(2026-10-21). The swap (the peg opening, the old card dropping, the new one
sliding in) is 1.7 times as slow as before, so the old card is seen leaving
before the new one lands (it slides in until 1.29 s); the clamp, the swing and
the check keep their shape and come 0.53 s later (`Peg.Beat.pinDelay`), and the
copy may not grow past 3 s. Every duration and curve is a token in `Design.Motion`; nothing
is hard-coded in a view. With Reduce Motion every transition is an opacity
crossfade or the end state, and decoration (the breathing viewfinder, the
celebration, the header's nod) does not play.

A `MenuBarExtra` label reaches the status item as a static image and symbol
effects never run there (spike F-menubar-anim), so Peg's moments are drawn
frame by frame by a 30 fps timer that runs only while one plays (`PegFlash`):

| Moment | When | Length | Reduce Motion |
|---|---|---|---|
| Copy | every copy | 2.9 s | the copied pose held 1.4 s on one timer |
| Attention | when something first needs fixing | 2.0 s | the "!" pose at once |
| Pause | Copy to clipboard switched off (also by Shortcuts or a Focus) | 0.6 s | the dashed card at once |
| Resume | Copy to clipboard switched on (also by Shortcuts or a Focus) | 0.9 s | the picture at once |
| Release | Move to Trash from a row, its menu or a floating preview | 1.2 s | the open, empty jaws held 1.2 s |
| Grip | Undo of that move | 0.9 s | the picture under the open jaws held 0.9 s |
| Squeeze | the click on the icon that opens the popover | 0.2 s | nothing |

Copy and attention come unasked, so they are slow enough to catch at a glance;
pause and resume answer a switch the user is looking at in the popover, so they
are short. Release, grip and squeeze answer the user's own action where it
happens, so they are shorter than the copy: on Move to Trash the jaws open, the
card drops out of the frame and fades, the jaws snap shut on nothing, and after a
beat the resting card comes back; on Undo the card on show fades, a picture rises
into the open jaws and Peg clamps with the copy's bite; on the click that opens
the popover the handles are pressed together, the jaws open a point and Peg
springs back, while the popover opens (it never waits for Peg). Retention, Clean
up now and "Also clean up N older screenshots" play nothing, whatever they move;
a Move to Trash or an Undo that fails plays nothing either. Closing the popover
plays nothing.

Precedence (`PegMoment.replaces`): among copy, release and grip the latest
wins, so a Move to Trash right after a copy (the common case: trashing a bad shot
from its floating preview) lets the card go at once, and a copy right after a
Move to Trash pegs the new one up. A change of state (attention, pause, resume)
replaces anything but a copy, and no release, grip or squeeze cuts it short. The
squeeze replaces only a squeeze and cuts nothing short. A moment that may not
replace the one playing does not play. One that may starts from the pose on show
(`Peg.pose(...handoff:)`): the card on show is the one that drops, fades or
swings, and the peg, the line and any other card ease from where they were into
the new moment, linearly within `menuBarHandoff` (0.15 s), so nothing jumps; an
ease in and out made up the distance faster in its middle frames than either
moment moves on its own. A card that was leaving (a release's or a copy's falling
card, a grip's fading one) is never frozen or pulled back: it goes on at its own
speed (`Card.fall`) and fades out within the hand-off while the new moment's card
comes in. A change of state hands over the pose drawn before the state changed. With Reduce Motion a
release or grip replaces the copy's hold with its own, and a change of state ends
a release's or grip's hold, so its state shows at once.

Each ends exactly on its resting pose; an attention fixed while Peg
still swings ends at once on the new resting pose. A copy plays over an attention (it did
happen) and ends on the card the icon rests on, dashed while paused or "!"
while something needs attention; a change of state never cuts a copy short. The
floating preview's Copied badge and the tour's check bounce as Peg's clamp
bites (`Design.Motion.pegged`, derived from `Peg.Beat`, 1.37 s after the copy
since the swap was slowed), so a retime keeps the three in step.

In the app:

- Floating preview: arrival, landing, badge bounce (again after Copy again),
  stack, drop and fling as before; hover lifts the picture 2 pt and spreads its
  shadow (the pointer handling stays put; nothing with Reduce Motion); while a
  swipe is held past the point where letting go dismisses it, the card tips 2
  degrees and fades a little, with a Force Touch trackpad tick; a file drag
  carries the picture larger, raised and shadowed while the card ghosts; "+N"
  pops in.
- Popover: a row Undo puts back grows into the strip's place; with several
  strips (one per move to the Trash in the same window) each closes in its own
  place, and all close together when the window ends; the header's symbol nods
  once per new problem.
- Tour: each step's symbol appears with draw-on (a fade for symbols without draw
  data, which `folder`, `camera.viewfinder` and `trash` are on macOS 26); the
  folder turns into the viewfinder in place; while Try it waits, the viewfinder
  breathes and Peg waits, half as large again, beside "Watch the menu bar", then
  plays the menu bar's own frames; the first copy ever bursts small cards from
  the check inside the result's card, once per install; a step's words change
  in turn, never on top of each other; the current dot slides to the next step.

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
- **An entry is no proof.** The ledger is a file in the user's Library that any process of
  theirs can write. It is read as untrusted (`ScreenshotLedger.read`): a regular file of
  the user (no symlink), at most 32 MB, version 1, and only well-formed entries (an
  absolute path without `.` or `..`, a device-and-inode identifier, a size, a date); the
  rest are dropped and the log counts them. Everything that lists or copies a ledger file
  (the popover, Get Latest and Copy Latest, `clipshot latest` and `copy`) also requires
  the screenshot marker on the file itself (`RecentScreenshots.select`,
  `AppModel.isTracked`): writing that marker on a file in a protected folder already needs
  access to the file. Only the last copy, held in memory, is listed without it (an edit
  Markup saved without the marker). Retention revalidates the marker before every move.

Retention runs at launch, every hour and after wake, one run at a time, at most
500 files per run. It only runs on a folder the user confirmed with a preview.
`FolderGuard` refuses, after resolving symlinks, the home folder and its
ancestors, `~/Library`, system locations and volume roots, and any folder whose
volume has no Trash. Files leave the folder only through `FileManager.trashItem`;
Undo moves the same file back.

## Shortcuts

App Intents in `ClipShot/Intents/ShortcutsActions.swift`, the logic in
`UI/AppModel+Shortcuts.swift` (Addendum C):

| Action | What it does |
|---|---|
| Get Latest Screenshot | The newest screenshot, as a file (name and type kept). |
| Get Recent Screenshots | The newest 1 to 10 (Number of Screenshots, default 1), newest first, at most 512 MB in all. |
| Copy Latest Screenshot | Copies the newest one to the clipboard, also while paused. |
| Pause Copying, Resume Copying | The popover's Copy to clipboard switch. |
| Clean Up Old Screenshots Now | Retention's run now; Preview Only counts without moving. Returns the count. |
| Focus filter "Copying During Focus" | Pause copying while the chosen Focus is on. |

- **Same paths as the app.** The screenshots are the popover list's choice
  (`RecentScreenshots.select`: ledger screenshots in the watched folder that still exist),
  read through `FileTrust` and handed over as data, never as a path. A file FileTrust
  refuses is skipped for the next newest. Get Recent stops before the bytes it holds pass
  512 MB (each file is at most 256 MB) and says so in its dialog. Copy is the row's
  Copy (`copyExplicitly`, then `writeClipboard(.again)`): the same PNG, owner, total and
  Peg copy moment. Pause and Resume set the switch through `setCopying`, so Peg plays
  pause and resume. Clean Up is `cleanUpNow()`, so the ledger, the revalidation before
  each move, `FolderGuard`, the confirmed-folder rule, the 500 cap and the Trash-only rule
  all hold; Preview Only is the same scan without the run. It never turns retention on and
  plays no Peg moment. It reports what the run moved; a run dropped because the retention
  settings changed while it scanned is tried once more, then said. Errors are said in the
  user's language (`ShortcutError`).
- **No window.** Every action has `supportedModes = .background` (what `openAppWhenRun =
  false` was before macOS 26). The system launches ClipShot in the background when it is
  not running; `IntentHost.model` is set in `ClipShotApp.init`, and Get waits up to 2 s for
  the coordinator to name the folder on such a launch.
- **A background launch is a full launch.** When a shortcut or a Focus change launches
  ClipShot (say the user had quit it), it starts as at login: it watches the folder, copies
  new screenshots (unless paused), runs retention's start-up cleanup when retention is on,
  and stays in the menu bar afterwards. That is how App Intents run in an app's process.
- **Not before the tour.** Until the welcome tour is completed (`tourCompleted`) every
  action, the read-only ones too since they would touch the folder, and the Focus filter
  say "Finish setting up ClipShot first" and change nothing, also while the tour already
  watches. The Focus filter's last report is kept and applied when the tour is done.
- **Focus.** `Preferences.focusPause` keeps a Focus pause apart from the switch:
  `focusOn` (a Focus whose filter pauses copying is on) and `pausedCopying` (that Focus
  switched copying off). A Focus turning on pauses copying unless it is off already; its
  end resumes only what it paused. Any use of the switch by hand (popover, Settings, the
  tour, Pause or Resume Copying) clears `pausedCopying`, so a Resume during the Focus wins
  until the Focus changes, and a pause by hand is never undone by the Focus. The same
  report twice changes nothing. A Focus's end resumes after a 1 s grace
  (`focusOffGrace`): a switch straight from one pausing Focus to another reports the end
  of the first, then the next, and copying stays paused through it with no Peg moment. No
  Focus identity is delivered, so a switch that reports only the next Focus is not seen
  as a change. The filter's parameter defaults to off because the system hands a filter its
  default values when the Focus ends (WWDC22 "Meet Focus filters"); its description says to
  turn it on. macOS does not tell an app which Focus is on, so the popover says "while a
  Focus is on", and only while a Focus that paused copying is known to be on.
- **The Focus at launch.** `reconcileFocusAtLaunch` reads the filter's `current` value
  once (5 s timeout), applies it at once and logs it, so a Focus that ended or began while
  ClipShot was not running counts, and a Focus that ended within the grace just before
  ClipShot quit (no Focus on, the pause still the Focus's) resumes copying. When the read
  fails or times out, copying is not left paused on a guess: a pause the Focus made is
  lifted, a pause by hand stays, the stored Focus state is cleared, and the log names the
  error type. While the read runs, the popover does not say a Focus paused copying. Check
  "Focus ends while ClipShot is quit, then relaunch" on a signed build before a release:
  `current` with no Focus on cannot be observed in tests.
- **Phrases.** `ClipShotShortcuts` (an `AppShortcutsProvider`) has two phrases per
  action except Get Recent (its count cannot be spoken), translated in
  `Resources/AppShortcuts.xcstrings`; every translation keeps `${applicationName}`, and the
  phrases use plain spaces, no no-break spaces. Titles, descriptions and parameter names
  are literals in the intents (the metadata is read from the source at build time) and
  keys of `Localizable.xcstrings` like every other string.

`ShortcutsTests` checks the metadata the build extracted into the app
(`Metadata.appintents`): every action, no window, the phrases and their six translations.
The build log has no `appintentsmetadataprocessor` warnings; check it after changing an
intent (`ExtractAppIntentsMetadata` step). `make l10n` reads the same metadata: a summary
with a number parameter must be count-neutral ("Get recent screenshots (${count})") or
have plural variations in every language.

Every Debug build is an app with these actions. xcodebuild registers what it builds with
LaunchServices, so `scripts/screenshots.sh`, `motion-demo.sh`, `readme-hero.sh` and `status-item-probe.sh`
unregister their Debug build on exit (`lsregister -u`); otherwise the Shortcuts app can
list a second ClipShot. `make test` and `make l10n` (`check-localisation.sh`) do the same
afterwards, pass or fail, through `scripts/unregister-debug.sh`, which also unregisters
the apps inside (Sparkle's Updater.app). A test run started another way, from Xcode say,
stays registered until it is unregistered or deleted.

## CLI

`clipshot`, for scripts, terminals and coding agents (Addendum C). Its logic is in
`ClipShot/Control/` (compiled into the app too, so the suite runs it in process); the tool
itself is `ClipShotCLI/main.swift`, the Xcode target `clipshot-cli`, which compiles
`ClipShot/Core` (without `PegFlash.swift`, which needs the UI's design tokens) and
`ClipShot/Control`, not a copy of them.

| Command | What it does | Needs the app |
|---|---|---|
| `clipshot`, `clipshot status [--json]` | Copying on or paused, and why (`manual`, `focus`, `setup`, `notRunning`; none while the launch still reads the Focus), the folder, cleanup, the latest screenshot, and the popover's attention rows by kind (`attention`); `copying` is false while one stops copying (`destinationNotFile`, `folderAccessDenied`). | No |
| `clipshot latest [-n N] [--json]` | Paths of the newest 1 to 10 (`RecentScreenshots.maxRequested`, as Get Recent Screenshots) screenshots, newest first, one per line. | No |
| `clipshot copy [PATH \| --latest] [--json]` | Copies the latest screenshot, or PATH, to the clipboard. | Yes |
| `clipshot pause`, `clipshot resume` | The Copy to clipboard switch. Already so: exit 0, says so. | Yes |
| `clipshot clean [--dry-run] [--json]` | Retention's run now; the dry run lists what would go. | Yes |
| `clipshot help [COMMAND]`, `--help`, `--version` | Help; the version, which is the app's. | No |

Exit codes: 0 ok, 1 error, 2 usage (an unknown command or flag, with that command's help;
with `--json` also `{"error":{"code":"usage",...}}` on stdout),
3 ClipShot is not running (the message says `open -a ClipShot`). Errors go to stderr, so
`$(clipshot latest)` never takes one for a path; with `--json` the error object
(`{"error":{"code","message"}}`) is on stdout too. `--json` output writes every key, `null`
included. Messages are English, like the log; the refusals are the Shortcuts' own English
words.

- **Same paths as Shortcuts.** The app answers on the main actor through the Shortcuts'
  model methods (`UI/AppModel+Control.swift`): `latest` is Get Recent Screenshots' choice
  (`recentScreenshots`, then `FileTrust`, a refused file skipped for the next newest) as
  paths; `copy` is `shortcutCopyLatest`, or for a PATH the row's `copyExplicitly`, so the
  PNG, the owner of the clipboard, the total and Peg's copy moment are the same, also while
  paused (Copy Latest takes the newest file `FileTrust` reads, the one `latest` names);
  `pause` and `resume` are `shortcutSetCopying` (`setCopying`: a pause by hand is never
  undone by a Focus, a resume during a Focus wins until the Focus changes, Peg plays pause
  and resume; a `pause` while a Focus holds the pause makes it the user's, reported as a
  change with `tookOverFocusPause`); `clean` is `shortcutCleanUp` (ledger, revalidation, `FolderGuard`, the
  confirmed folder, 500 per run, Trash only, no Peg moment). Every command but `status`
  refuses until the welcome tour is completed, as Shortcuts do.
- **`copy PATH`.** The tool makes PATH absolute against its working directory; the app
  copies it only when it is a screenshot ClipShot tracks, one the popover could list (in
  the ledger and still marked as a screenshot, or the last copy, as the same file:
  `AppModel.isTracked`), directly in the
  watched folder (the folder's symlinks resolved, the file's never followed), and
  `FileTrust` reads it (a regular file of this user, at most 256 MB). Anything else, any
  other image in the folder included, is refused with the reason (`notInFolder`,
  `refusedFile`; "No such file" for a missing one). ClipShot holds the folder access
  (Desktop, Documents and Downloads are protected by macOS): without the ledger rule, any
  process of the user, one without that access included, could have ClipShot put a Desktop
  PDF on the clipboard and read it back. The popover's rows, the floating previews and
  Copy Latest Screenshot only ever offer marked ledger screenshots or the last copy
  (`RecentScreenshots.select`). The copy, Get Latest, Get Recent and `latest` then read
  the file that was chosen: FileTrust compares the descriptor's device and inode with the
  chosen file's (`Policy.expectedResourceID`) and refuses another file swapped in at the
  path; the listing ones skip it for the next newest.
- **Without the app.** `status` and `latest` read for themselves, read-only: the ledger, the
  folder macOS screenshots go to (`~/Desktop` while it is missing, as the app watches) and
  the app's own settings (the `sk.moravcik.ClipShot` defaults domain). `latest` uses the
  same `RecentScreenshots.select` and `FileTrust` rules; before the tour it refuses too.
  `status` reports cleanup's refusal as the app does (`RetentionPolicy.refusal`: not
  confirmed for this folder, a system folder, no Trash).
  The tool writes nothing: not the ledger, not the log (`Log` goes to /dev/null), no
  preference.

### The control socket

State changes go through the running app, over a Unix domain socket at
`~/Library/Application Support/ClipShot/clipshot.sock`; nothing that can change state is
reachable from a web page (no URL scheme, no network listener). `ControlHost` starts it at
launch with the app's model; never under XCTest, the harness or the probes.

- **The folder** must be a real folder owned by the user; it is made 0700. The socket is
  0600 before it can be found.
- **What is at the path** is read with `lstat` and never followed. A symlink, a file, a
  folder or another user's socket: the server does not start (and the tool does not
  connect: "not ClipShot's socket"). A socket of this user that nobody answers on is a
  leftover from a crash and is replaced; one that answers is another running ClipShot (a
  Debug build next to the installed one) and is left to it. Replacing never deletes: the
  new socket is bound under a temporary dot-name in the folder and renamed over the path.
  The socket file stays after quitting; `clipshot` then gets "connection refused" and says
  ClipShot is not running.
- **Each connection** is checked with `getpeereid` before a byte is read: a peer of another
  user is closed unanswered (the tool checks the server the same way). One JSON request,
  at most 16 KB, within 2 s; one JSON response, at most 4 MB, written within 5 s; then the
  connection closes. At most 8 at once; a ninth is answered `busy` ("try again"), not
  closed silently. Each command has a deadline, 25 s, 170 s for `clean`: past it the app
  answers `timedOut` and frees the place, while the work it started may still finish. The
  tool waits a little longer (30 s, 180 s), so it gets that answer. Descriptors are
  non-blocking, close-on-exec and never raise SIGPIPE; every read and write waits in `poll`
  against a deadline.
- **Started off the main thread.** The folder checks, the probe of a socket left behind,
  bind and rename run on a utility task, so launch never waits on them. When another
  instance still answers (a relaunch while the old one exits), it tries once more after
  2 s. A start that fails is logged (`control socket not started: ...`).
- **Running, but no socket.** When nothing answers, the tool asks Launch Services whether
  ClipShot runs. If it does (the socket could not be started: a symlinked
  `Application Support/ClipShot`, say), every command says so and to check the log and
  reopen ClipShot (exit 1, `socketUnavailable`) instead of "not running"; `latest` still
  reads for itself.
- **Versioned.** Every request and response carries `"v": 1` (`ControlProtocol.version`),
  read before the rest; another version gets a clear error on both sides instead of a
  guess. An unknown command or a request that is not JSON is `badRequest`.
- `CLIPSHOT_SUPPORT_DIR` makes the tool look for the socket and the ledger in another
  folder: for tests and development. The app always uses its own. With it, the running-app
  checks below are off (that socket is never the app's), and a Debug build of the tool
  reads the app's settings from `CLIPSHOT_DEFAULTS_DOMAIN` when set (release builds ignore
  it).
- **Right after a launch** the socket may not be bound yet (the server starts off the main
  thread, and waits 2 s for a quitting instance). When nothing answers but ClipShot runs and
  was launched within the last 10 s, the tool tries again every 100 ms for up to 3 s
  (`startupGrace`) before it says the socket is unavailable. Not running at all is said at
  once.
- **A temporary socket left behind** (the app died between bind and rename, or a step
  failed) is swept at the next start: `.clipshot-<pid>-<n>.sock` sockets of this user, of
  another process, that nobody answers on, are renamed over the socket path, which the new
  socket's rename then replaces. Nothing is deleted, nothing else is touched.

### How it ships

Inside the app, at `ClipShot.app/Contents/Helpers/clipshot`, built by the app's scheme (an
embed phase of the `clipshot-cli` target): signed, notarized and stapled with the app, and
always the app's version (`--version` reads `CFBundleShortVersionString` from an Info.plist
embedded in the binary). Not `Contents/MacOS`: on a case-insensitive volume `clipshot` there
is the app's own `ClipShot` executable. VibeRes builds its CLI from source in a Homebrew
formula; ClipShot does not need one:

- **Homebrew**: the cask's `binary` stanza links the bundled tool into Homebrew's `bin`, so
  `brew install --cask m-moravcik/clipshot/clipshot` puts `clipshot` on the PATH.
- **The ZIP** (and Sparkle updates, which keep the path): **Install…** in Settings >
  General makes the link (below), or a link by hand. On Apple Silicon `/usr/local/bin`
  may not exist and is root's:
  `sudo mkdir -p /usr/local/bin && sudo ln -s /Applications/ClipShot.app/Contents/Helpers/clipshot /usr/local/bin/clipshot`.
- **From source**: `make install-cli` (to `/usr/local/bin/clipshot`, as VibeRes;
  `PREFIX=` to change; `sudo` when that folder is root's), `make uninstall-cli` moves it
  to the Trash.
- **One of them only.** On Intel, Homebrew's prefix is `/usr/local`, so the cask links
  `/usr/local/bin/clipshot` too: with a hand-made link or `make install-cli` there, `brew
  install` refuses to link over it. Remove the other one first (`make uninstall-cli`, or
  move the link to the Trash).

### Install from Settings

Settings > General shows where `clipshot` is (`UI/CommandLineSetup.swift`), in a Command
line section with commands and paths in the monospaced font (Markdown code spans in the
strings, kept by every translation). General is 470x450, the other tabs keep the siblings'
470x400: each tab sets its own size and the window resizes to the chosen tab, as macOS
Settings windows do.
`CommandLineStatus.detect` reads, with `lstat` and never following a link except to
resolve where it ends, `clipshot` in Homebrew's bin (`$HOMEBREW_PREFIX`, `/opt/homebrew`),
`/usr/local/bin` and `~/.local/bin`. A shell's PATH is not visible to a GUI app, so these
are the places checked. In order:

- **A Homebrew copy** (`UpdaterGate.isHomebrewCopy`, the same Caskroom check the updater
  uses) shows where the cask linked it and never offers Install.
- **A stale link** anywhere (it may come first on the PATH): dangling (the app was moved
  or deleted), or resolving to another `*.app/Contents/Helpers/clipshot` that Homebrew did
  not install. **Fix…** asks for confirmation, naming where it points, then replaces that
  link.
- **A link that resolves to this app's tool** (`realpath`, so a relative link or a
  symlinked `/Applications` counts): installed, with where.
- **A link into a ClipShot.app the cask installed** (`CommandLineLocations.homebrewBundles`,
  its Caskroom entries resolved), seen from any other copy such as a Debug build: the cask's
  own link, shown as installed by Homebrew; never offered Fix.
- **Anything else** named `clipshot` (a `make install-cli` copy, another program, a
  link to one, a folder): said and left alone, with Show in Finder; no prompt.
- **Nothing**: **Install…** links `/usr/local/bin/clipshot`; **Copy Command** copies the
  `sudo ln -s` line with this app's path, quoted for the shell.

A copy running from App Translocation (opened from Downloads without moving it) is asked to
be moved to Applications first: a link to the translocated path breaks at the next launch.

`ScriptLinker` runs `/usr/bin/osascript` with a fixed AppleScript; out of process, so the app
keeps copying screenshots while the password prompt is open. The paths reach it as
arguments, AppleScript quotes each with `quoted form of`, and a fixed `/bin/sh` script reads
them as `$1` to `$3`: no path is ever spliced into code. `do shell script ... with
administrator privileges` (the standard prompt, with a localised message) is used only when
the folder, or the nearest one above it that exists, is not writable; otherwise the same
script runs as the user. The script creates the folder, then either `ln -s` without `-f`
(nothing may be at the path; a folder there is refused rather than linked into), or, for
Fix, checks that the path is still a symlink with the target the user confirmed, makes the
new link under a temporary name and renames it over the old one (`mv -fh`). Nothing is
deleted and a regular file is never replaced. Its exit codes and a cancelled prompt (-128)
come back as `CommandLineLinkResult` and are said under the row.

`scripts/release-signed.sh` signs the tool with the Developer ID identity, its own
identifier `sk.moravcik.ClipShot.cli`, the hardened runtime and a timestamp, before the
app, then checks it like every signable item (team, Developer ID authority, runtime,
timestamp, no debug entitlements) and checks that it is universal, carries no entitlements
(re-signing drops the application identifier Xcode's signature had) and prints the app's
version. `verify_app` in `scripts/release.sh` repeats those checks on the built app, the
local ZIP and the downloaded asset.

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

ClipShot's own symbol, Peg: a picture pegged on a line (a clothes peg on a darkroom line), drawn in `UI/Peg.swift`
with Core Graphics as one template image per pose, in a fixed 22 x 16 pt frame
so the status item never changes width and the menu bar never scales it down.
Each state has its own silhouette:

| | |
|---|---|
| The picture on the line | Copying on. |
| A solid card with a check | A copy just landed. |
| A dashed, empty card | Copying is off. |
| A tilted card with "!" | Something needs fixing. |

On every copy the peg opens, the last shot drops, the new one slides in along
the line, gets pegged with a squash, swings and bobs, develops from the bottom
and shows the check, then turns back into the card it rests on: 87 frames in
2.9 s (`Peg.pose(at:from:to:)`, driven by `PegFlash`). Its other moments swing
the card into the "!" pose, break the outline into dashes, join it up again, let
the card go to the Trash, grip it again on Undo and squeeze the peg as the
popover opens (see Motion). With Reduce Motion the copied card is held for 1.4 s, no
movement, and the other states change in one frame. The idle glyph is as tall as VibeRes's, no
wider than Eject Guard's drive and drawn in the same stroke weight; tests pin
all three.

`scripts/screenshots.sh` renders every state and every frame of the copy
animation (`menubar-states.png`), every frame of every moment, and of moments
that replace one still playing (`menubar-moments.png`, and one PNG per frame in
`peg-frames/` at 4x, `peg-frames@1x/` and `peg-frames@2x/` at the menu bar's
own pixels, for GIFs), and the optical size next to VibeRes and Eject Guard
(`menubar-optical-size.png`).

### Knowing the popover opened

A `.window` MenuBarExtra gives no click callback, and its status item button
belongs to SwiftUI (no target or action). ClipShot learns of the click from the
popover's window: `WindowVisibilityReader` reports it open when it is ordered in
and either key or unoccluded, whichever the window server reports first, so the
squeeze can start with the click. On a stand-in panel (see below) the window
became key before it was reported unoccluded; on the real popover that order is
still to be checked live. Closing reports closed only once the window is off
screen. Only a fresh open squeezes: one after the window was ordered out
(`PopoverPresence`). An occlusion round trip while it stays ordered in (a display
asleep, another Space) refreshes the popover but plays nothing
(`WindowVisibilityReader.isOpen`, `AppModel.popoverVisibilityChanged`).

The squeeze moves 1 pt, too little to survive anti-aliasing at 1x, so its jaw
opening and the narrowing of each handle are drawn in whole device pixels
(`Peg.snapped`): 1 px at 1x, 2 px for the jaw and 1 px a side for the handles at
2x.

### The label in the menu bar while the popover is open

`scripts/status-item-probe.sh` runs a Debug build's real `MenuBarExtra` on demo
data, opens the popover by pressing its own status item button in-process, plays
a Copy, a Move to Trash and an Undo from the popover's rows, and records the image
the status item button holds at each step (`build/status-item-probe/`). It never
captures the screen. On 2026-10-20 every sample was the model's frame or the one
before it (the label is redrawn on the next display pass): 22 distinct images
during a copy, 11 during a release, 9 during a grip. On that Mac a menu bar
manager (Thaw) hid the Debug build's item, so its MenuBarExtra could not open
and the probe used a stand-in: the popover's own view in a key panel of the app.
That proves the label keeps animating while one of the app's windows is open and
key; run the probe with the Debug item allowed in the menu bar to check the real
popover.

## Languages

English, Slovak, Czech, German, Spanish and French, in String Catalogs
(`ClipShot/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` for the
folder access prompts and `AppShortcuts.xcstrings` for the Siri phrases). The English text is the key, defined once in
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

ClipShot, VibeRes and Eject Guard sign updates with the same EdDSA key. This is
an accepted risk, chosen on purpose: one key to guard and back up instead of
three.

Where the key is and what reads it: the private key is in the login keychain of
the release Mac, with an offline backup. During a release two Sparkle tools from
the SwiftPM artifact read it, and macOS asks before each does: `sign_update`
signs and verifies the archive and the feed, and `generate_keys -p` prints the
key's public half, which must equal the `SUPublicEDKey` the app ships or the
release stops. With `SPARKLE_EDDSA_PRIVATE_KEY_PATH` set, `sign_update` reads the
key from that file instead (then the key also sits in a plain file), and the
check signs a throwaway file and verifies it against `SUPublicEDKey` with
CryptoKit. Both tools are ad-hoc signed upstream, so their signature proves
nothing. Instead the committed `Package.resolved` pins Sparkle's revision,
SwiftPM checks the artifact against the checksum in Sparkle's `Package.swift`,
and `scripts/sparkle-tools.sh` pins the SHA-256 of both binaries: a release
refuses to run a tool that does not match. `make guards` keeps the version in
`project.yml`, `Package.resolved` and the tool hashes in step.

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
   `make test l10n guards`, the notarytool profile works, Sparkle's tools match
   their pinned hashes, and the signing key's public half is the shipped
   `SUPublicEDKey`. An inherited `SKIP_NOTARIZE` is cleared.
2. `scripts/release-signed.sh`: Release build with the Developer ID identity,
   Sparkle's nested helpers re-signed, every signable item checked for Developer
   ID, hardened runtime, timestamp and no debug entitlements, universal binary,
   notarized, stapled, zipped to `artifacts/ClipShot-<version>.zip`.
3. Verify what will be published, for the built app and the app inside the
   ZIP: bundle id `sk.moravcik.ClipShot`, version and build number exactly those
   in `project.yml`, `lipo -archs` is `x86_64 arm64`, signed by the expected
   team (`TEAM_ID`), `SUPublicEDKey` as in `project.yml`, no `get-task-allow`, `spctl -a -vv` says Notarized
   Developer ID and `stapler validate` passes; `Contents/Helpers/clipshot` is universal,
   verifies, is signed by the team as `sk.moravcik.ClipShot.cli` with the hardened runtime,
   carries no entitlements at all and prints this version. The ZIP's top level must be
   exactly `ClipShot.app`: Sparkle installs any bundle in the archive that has
   the app's name or bundle id, so nothing else may be in it.
4. Rehearse the appcast on the local ZIP into a temporary feed, with both
   signatures verified and the signing key checked again. Any appcast or key problem, and the keychain prompt,
   comes up here, while nothing is public.
5. Commit "Release X" (empty), tag `vX`, push both atomically.
6. `gh release create` with the ZIP and the notes file.
7. Download the asset back from GitHub and give it every check of step 3, in
   every mode; when the local ZIP is still there, it must also match it byte for
   byte. Then build the appcast from those bytes (`scripts/make-appcast.sh`
   signs the feed and verifies the enclosure signature and the feed signature),
   commit and push `appcast.xml`.
8. Fetch the feed and the asset as a client would: verify the feed's own
   signature, and check the length and the enclosure signature against the
   asset.
9. Copy `Casks/clipshot.rb` into the tap (the local tap clone, `TAP_DIR`) with this
   release's version and sha256, `brew audit --cask --strict --online`, `brew style`,
   push.

It is interactive: `sign_update` and `generate_keys` ask for access to the EdDSA
key in the keychain (set `SPARKLE_EDDSA_PRIVATE_KEY_PATH` to use a key file
instead). Nothing
public is rolled back. If tagging or the push fails, the script prints the
commands that undo the local release commit (and the tag, when it was made). If a step after the tag fails, it
says what is already public and how to finish:

```sh
scripts/release.sh --resume-from appcast
```

That mode skips the build, the tag and the GitHub release. It requires the tag
on origin and the release with its asset, downloads the asset again, and
continues from step 7. Nothing is signed into the feed unverified: the
downloaded asset always gets the full step 3 check, and the byte comparison
with the local ZIP is added when that ZIP is still there. The other preflight
checks still run, except the tests, the
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
ClipShot/Intents/   Shortcuts actions, the Focus filter and the App Shortcuts phrases
ClipShot/Control/   clipshot: the control socket, its protocol, the commands; in the app and the tool
ClipShotCLI/        clipshot's main.swift
ClipShot/Preview/   Debug only: the screenshot harness, the motion demo, the README hero, demo data
ClipShot/Resources/ String Catalogs (app, Info.plist, App Shortcuts phrases)
ClipShot/AppIcon.icon   Icon Composer document
ClipShotTests/      Swift Testing suites; fixtures from the spike and for l10n
scripts/            release, appcast, screenshots, README hero, motion demo, status item probe,
                    guards, l10n, spike probes
docs/               spike, translations, README pictures and hero GIFs, design and plan
release-notes/      one file per version
Casks/              the Homebrew cask, copied to the tap on each release
```

Swift 6 language mode, strict concurrency complete, warnings as errors, Debug and
Release. `project.yml` is the source of truth; `ClipShot.xcodeproj` is generated
by XcodeGen and not committed; `Package.resolved` at the root is, and XcodeGen's
`postGenCommand` copies it into every generated project. The only dependency is
Sparkle.

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
| `FloatingPreviewsTests`, `UndoAndFailureTests` | Copied, the hover's Copy again and the popover's rows follow one owner, compared by resource ID; a failed Copy, Move to Trash or Undo is said where the user acted. |
| `MultiUndoTests` | Several moves to the Trash in one window: each keeps its own strip in its own place and its preview's Undo, also when the moves overlap; one shared window, extended by each move and not by an Undo, ends them all (on a `ManualTimerClock`); ⌘Z puts back the latest first, a strip or preview only its own; a failed put-back ends only that Undo; totals and Peg follow every move and Undo; where the strips go when a new screenshot or a preview's file joins them, or there are more than places. |
| `UpdaterGateTests`, `SparkleConfigurationTests` | Ad-hoc and Homebrew copies never self-update; the feed and key are what releases expect. |
| `LocalisationTests` | The l10n gate fails on the broken catalogs in `ClipShotTests/Fixtures/l10n`. |
| `StatusIconStateTests`, `PegFlashTests`, `PopoverLayoutTests` | The menu bar label is never scaled and fits its frame; every state has its own silhouette; Peg matches the siblings' height, width and stroke; the copy animation starts and ends at rest, one timer tick per frame and none after; Reduce Motion holds the copied pose; the bounces are derived from Peg's clamp; the popover's bottom soft scroll edge. |
| `PegMomentTests`, `PegMomentModelTests` | Every moment starts where the icon rested and ends exactly on its resting pose, every frame is a template image that fits the canvas; the model plays them on real state changes only, once, never cuts a copy short, leaves no timer behind, and plays none with Reduce Motion. |
| `PegActionMomentModelTests`, `PegHandoffTests` | Move to Trash from a row or a preview plays the release, Undo the grip, a fresh open of the popover the squeeze (`PopoverPresence`, and the reader's wiring on a real window); retention, Clean up now, "Also clean up", a refused move, a failed Undo and closing the popover play nothing; precedence (the latest of copy, release and grip wins); a moment that replaces another starts from the pose on show (drawn pixel for pixel), changes no frame of the hand-off more than the two moments do on their own, lets a falling card finish falling, and ends at rest; the squeeze moves whole pixels at 1x and 2x; Reduce Motion holds the key poses on one tick and never squeezes. |
| `ShortcutsTests` | The actions pick what the popover lists and hand out existing files only (never one outside the folder or a symlink; a refused newest falls back to the next; Get waits for the folder on a launch; the 512 MB cap); Copy Latest Screenshot leaves exactly what the popover's Copy leaves, also while paused; Pause and Resume play the switch's moments; Clean Up keeps retention's refusals, and Preview Only counts what the run then moves; the Focus precedence matrix, a switch between pausing Focus modes, its relaunch and the launch read (known, failed, timed out); nothing runs before or during the tour, and a Focus reported during it applies at its end; the extracted metadata and the phrases in six languages. |
| `CommandLineSetupTests` | Settings' Command line on a temporary "/": not installed, a link to this app's tool in each place (also relative or through a linked folder), a Homebrew copy never offers Install, a dangling link or one to another ClipShot is stale and fixed only at that path, the cask's link into a ClipShot it installed is Homebrew's from any other copy and never fixed, a regular file, a link to another program or a folder is refused with no action, a stale link wins over a working one, the translocated app. The real linker without the prompt into temporary folders: creates the folder, never replaces anything on Install, replaces on Fix only the link still pointing where it did, paths and targets that look like shell code are data, a missing tool; osascript's answers, cancel included; the password prompt only for a folder that is not the user's. Nothing touches `/usr/local/bin`, `/opt/homebrew/bin` or `~/.local/bin`. |
| `ControlServerTests`, `CommandLineToolTests`, `CLIBinaryTests` | The socket: a round trip; 0700 and 0600; another user's peer closed unanswered; an oversize, silent, non-JSON or other-version request refused before the handler; a symlink, file or folder at the socket path neither followed nor replaced, a stale socket replaced, a live one left to its server, a symlinked folder refused; past the connection cap the answer is `busy`; a stuck command is answered `timedOut` at its deadline and frees its place; the client gives up at its timeout (all three with a gated handler, no fixed delays); stale temporary sockets of another process are swept by rename, a file, a live one and this process's own are left. The tool: its arguments and usage errors (JSON with `--json`), one `latest` maximum shared with Shortcuts, the JSON shapes (every key, `null` included), text output; through a real socket to the model, status and why copying is paused, pause and resume as the switch (Peg, the Focus rule), latest as the popover chooses, copy as the row's Copy also while paused, copy PATH refused outside the folder, for a symlink, a non-image, a missing file, and for any image ClipShot did not see being taken (an unmarked download, a PDF, a marked but untracked file; the last copy counts), the same through `handleControl` itself; Copy Latest and the popover offer tracked screenshots only; `latest` and `copy` agree on a newest file FileTrust refuses; a pause during a Focus pause is reported as taking it over; an attention that stops copying and the unknown Focus at launch in status; right after a launch the tool waits for the socket, says not running at once, and unavailable after the grace; clean and its dry run with retention's refusals, nothing before the tour; exit 3 without the app, `socketUnavailable` when the app runs without its socket; status (with cleanup's refusal) and latest from the files without it, and the real sources write nothing. The built binary inside the app: its version, help, exit codes, a round trip, a symlink not used, status against a stale socket. |
| `LedgerTrustTests` | A hand-written ledger listing an unmarked download makes nothing listable or copyable (copy PATH, copy, latest with and without the app, Get Latest, Copy Latest, the popover); a marked screenshot in it still is; malformed entries are dropped and logged; another version, garbage, a symlink or an oversize ledger is not read; a file swapped in at the path of the chosen one is refused by FileTrust and the copy fails. |
| `PreviewMotionTests`, `OnboardingTests` | The swipe commits exactly where a release dismisses; the drag image is lifted off its card; Copy again reports back so the badge bounces; the first copy is celebrated once per install, the burst stays small, short and ends. |

Tests never touch real preferences (`make guards` refuses `UserDefaults` in
tests) and use temporary folders. A check that something did *not* happen waits
for the work it is about to finish (the coordinator's `passesFinished`,
`eventsHandled`, `isIdle` and `refreshIdle`, the model's `recentSettled` and
`statusReads`, the retention scheduler's `isIdle`), not for a fixed sleep that
could end first and pass for nothing. The floating previews' lifetimes, the Undo
offer and the failure notes run on a `TimerClock`; their tests drive a
`ManualTimerClock` and check a moment before each deadline exactly.

The sleeps left (23) are there on purpose:

- real run-loop timers and "no tick after" checks of Peg's frame timer
  (`AppModelTests`, the copy animation and Reduce Motion tests);
- waiting for a released model to go (`AppModelTests`,
  `FloatingPreviewsTests`), where there is no model left to ask;
- `CopyCoordinatorStopTests`: a stalled IO queue has no completion signal;
- spacing between writes, so files get distinct creation times or land as a
  second display (`CopyCoordinatorTests`, `FloatingPreviewsTests`);
- `doesNotWatchBeforeOnboardingStep2` and `editedCopyIsNotWrittenWhilePaused`:
  nothing is running that could be waited on;
- `multiDisplayShowsOnePreviewWithExtraCount` waits 400 ms before it says no
  second preview appeared (a candidate for `copySettled`);
- `PopoverLayoutTests` (layout passes) and `RetentionSchedulerTests`'
  `runNow` ordering, where the outcome is the same either way.

## Safety notes

- Nothing under `ClipShot/` calls `removeItem` or `unlink`; `make guards`
  enforces it. User files leave the screenshot folder only through
  `FileManager.trashItem`; Undo moves the same file back from the Trash
  (`FileManager.moveItem`).
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
make cli             # the command line tool alone (it is also built into the app)
make install-cli     # to /usr/local/bin/clipshot (PREFIX=...); make uninstall-cli
```

`DERIVED_DATA=<dir>` builds `cli` and `install-cli` into that folder instead of Xcode's
default derived data.

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
scripts/readme-hero.sh          # render the README's animated hero into docs/hero.gif and docs/hero-dark.gif
```

It renders the popover in every state, every attention row, every Settings tab,
every tour step, the floating preview and its motion as key frames, the menu bar
states, the icon, and the popover under the menu bar and the 1920x1080 banner, in
light and dark.
Everything is demo data in `build/screenshots-scratch`: an in-memory
`com.apple.screencapture`, a pasteboard that never reaches the system, a Trash
that refuses every move. Nothing on the Mac that renders is read or changed. The
Debug build is coverage-instrumented; its profile goes into `build/`.

It also checks, in every language, that Settings > Capture with the destination
guard, and Settings > General in every state of its Command line section, keep at
least the Form's standard 20 pt under the last section, and fails the run when one
does not; that is how Restore was kept from scrolling out of view in German.

Off-screen, the popover's material has nothing to blur, so it is drawn as a solid
fill and the bottom soft scroll edge is left out. `CLIPSHOT_SCREENSHOTS_LIVE=1`
takes the popover pictures from a window on screen through ScreenCaptureKit
instead, over a demo desktop. That needs Screen Recording for the Debug build,
granted by hand; the harness never asks for it and stops with a message when it
is missing.

Motion is judged in motion: `scripts/motion-demo.sh` (light, or `dark`) plays
the real views on demo data live, in a floating window at the top left of the
main screen, for 30 s: the tour's Try it with Peg and the first-copy
celebration, the floating preview, the popover's Undo, its strip closing, its
header's nod, Peg's attention, pause and resume, and the popover's Peg letting a
row go to the Trash and gripping it again on Undo. Record the screen
meanwhile and crop to the window. Like the harness, it never touches this Mac's
screenshot settings, folder, clipboard or preferences. Hover, swipe and drag
need a pointer and a Force Touch trackpad, so they are checked by hand; their
end states are key frames in `preview-motion`.

The README's hero is rendered, not recorded: `scripts/readme-hero.sh`
(`Preview/ReadmeHero.swift`) draws the key moment frame by frame off screen on a
demo desktop, ⇧⌘4 and a selection, the real `PreviewCard` arriving on the
`Design.Motion` springs, Peg's copy moment in the menu bar and in a 3x loupe
(`Peg.pose(at:)`, so it follows `menuBarCopy`), then ⌘V into a demo note while
Peg's check is on. 231 frames at 30 fps (7.7 s), seamless: the last frames match
the first. It writes `hero.gif` (960 px, at most 5 MB, the run fails above),
`hero.mp4`, `poster.png` and a contact sheet per appearance into
`build/readme-hero/`, and copies the two GIFs into `docs/`; the MP4s and posters
are for the web and stay out of the repository. The Copied badge's bounce runs on
its own timer before the first frame is drawn, so the hero shows the badge without
its bounce.
