# Vision

`ClipShot` exists so that a screenshot is ready to paste the moment it is taken, while macOS still saves the file.
It serves people on a Mac who take a screenshot to hand it on, to a chat, a mail, a document or a coding agent.
It owns exactly one thing: what happens to a screen capture after macOS saves it.
Most screenshots are quick and used once, so ClipShot's job is done when the capture can be pasted, and anything that organises, names or archives screenshots has to prove a real need first.

## Paste works at once

The image is on the clipboard as soon as macOS saves the file, and a copy that waits is a defect in the main point of the app.
It goes on the clipboard as a picture, PNG data only, so chat apps, Mail and browsers paste the image and not an attachment.
Speed never costs the file: macOS still saves every screenshot where the user told it to.
When macOS itself holds the file back, ClipShot says so and offers the faster path instead of pretending.
Screen recordings macOS saves belong to the same job, under their own switches, and a short one may reach the clipboard as an animated picture when that pastes better than a file.
ClipShot only writes to the clipboard: it never reads, keeps or restores what the user had there, and a user who needs the clipboard left alone turns copying off.

## macOS does the capturing

The native shortcuts, the native capture UI and Markup stay as they are, and ClipShot never replaces them.
ClipShot does not capture, record, edit or annotate anything itself.
It changes a macOS screenshot setting only through a visible control, backs up what was there before its first write, and always offers the way back.
It never flips back a setting the user changed in ⇧⌘5 > Options and never kills a system process.
An update never silently changes how screenshots behave; a new default reaches an existing install as an offer.
A pause or resume the user sets by hand wins over every automation.

## Only real screenshots, only to the Trash

A file is a screenshot because macOS marked it as one when it saved it, never because of its name.
Files from other capture apps, which macOS did not mark, stay out of scope even as an opt-in.
Downloaded files, other users' files and anything outside the screenshot folder are never copied and never touched.
Nothing old lands on the clipboard: a file that was there at launch, arrived while copying was off, or was only moved or duplicated is not copied.
Files leave the folder only through the Trash, every move the user makes by hand has an Undo, and nothing is ever deleted.
Cleanup is off until the user turns it on themselves; no install, tour or update turns it on, because unlike launch at login it moves files.
Cleanup touches only screenshots ClipShot saw being taken, in the folder the user confirmed, and keeps every screenshot the user renamed.
How long screenshots stay is the user's choice, from hours to months.

## It says what happened

A copy, move or Undo that fails is said where the user acted, and never dropped silently.
A problem that stops ClipShot from working shows in the popover with a button named for its fix.
Peg, the menu bar icon, moves only when something happened, and every motion has a job.
There is no sound and no notification banner, because the macOS shutter already confirms the capture.

## Quiet, local, one app

At rest ClipShot costs next to nothing, well under 0.1 % CPU.
It talks to the network only to check for updates, and its log records counts and file types, never names or paths.
There is no telemetry, not even anonymous or opt-in; a problem reaches the author through the user's own Report.
The popover, Shortcuts and the `clipshot` command are doors into the same app: anything that changes state goes through the running app and all its checks.
Agents reach ClipShot through the `clipshot` command, the cheapest way for an agent to use it, and a second protocol for the same doors, such as an MCP server, needs a reason the command cannot cover.
Reading the text of a screenshot on the Mac, so an agent can read instead of look, may be tried as an extra next to the image, never instead of it.
Nothing that can change state is reachable from a web page or from another user.
Exactly one ClipShot runs at a time, because two copiers race for every screenshot.

## One of a family

ClipShot looks, installs, updates and speaks like VibeRes and Eject Guard: the same popover and settings, six languages, signed and notarized releases, Sparkle and a Homebrew cask.
It claims support only for what was tested on a real Mac.
A bug fix starts by reproducing what the user saw, in the real app.

## Scope

ClipShot is not a capture tool: no capture engine, no scrolling capture, no screen recorder of its own.
It is not an editor or an annotator; Markup is the editor.
It is not a clipboard manager: it keeps no clipboard history and restores nothing.
It is not a screenshot library: the popover keeps the last four at hand and the folder stays the archive, until real users ask for more.
It is not an uploader or a sharing service, and nothing goes to a cloud.
It is not a Mac App Store app and not sandboxed, because it must read the macOS screenshot settings and watch the folder the user picks.

A change aligns when it makes the way from the shortcut to the paste shorter or safer, keeps every file the user did not ask to move, and tells the user what it did.
A change should be resisted when it captures or edits on its own, touches a file macOS did not mark as a screenshot, deletes instead of trashing, turns on cleanup or changes a macOS setting without the user doing it, reads or keeps what the user had on the clipboard, or sends anything off the Mac besides the update check.
