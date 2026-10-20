import Foundation
import SwiftUI

/// Every user-facing string, in one place. English text is the key, as in VibeRes; the
/// catalog (`Localizable.xcstrings`) carries the translations and the plural forms.
/// `IssueReport` stays English on purpose: the maintainer reads it, not the user.
enum Copy {
    static let appName = "ClipShot"

    // MARK: - Status item and announcements

    enum StatusItem {
        static let idle = LocalizedStringResource("ClipShot, copying on", comment: "VoiceOver label of the menu bar icon")
        static let copied = LocalizedStringResource("ClipShot, screenshot copied", comment: "VoiceOver label of the menu bar icon")
        static let paused = LocalizedStringResource("ClipShot, copying paused", comment: "VoiceOver label of the menu bar icon")
        static let attention = LocalizedStringResource("ClipShot, needs attention", comment: "VoiceOver label of the menu bar icon")
    }

    static let screenshotCopied = LocalizedStringResource(
        "Screenshot copied", comment: "VoiceOver announcement after a screenshot went to the clipboard")

    // MARK: - Popover header

    enum Header {
        static let on = LocalizedStringResource("Copying on", comment: "Popover header state")
        static let paused = LocalizedStringResource(
            "Paused", comment: "Popover header state: the Copy to clipboard toggle is off")
        static let attention = LocalizedStringResource("Needs attention", comment: "Popover header state")
        static let pasteAfterThumbnail = LocalizedStringResource(
            "Paste works once the thumbnail disappears",
            comment: "Popover status row under Copying on, Preview mode macOS while the one-time offer shows: macOS saves the file when its floating thumbnail goes away")
        static let pasteAtOnce = LocalizedStringResource(
            "Screenshots are ready to paste at once",
            comment: "Popover status row under Copying on, Preview mode ClipShot or None: the copy lands the moment the screenshot is taken")
        static let pausedDetail = LocalizedStringResource(
            "New screenshots are not copied", comment: "Popover status row, under Paused: the Copy to clipboard toggle is off")
        static let pausedByFocus = LocalizedStringResource(
            "New screenshots are not copied while a Focus is on",
            comment: "Popover status row, under Paused: a Focus filter turned Copy to clipboard off; it comes back on when that Focus ends. Focus as macOS names it")
        static func attentionDetail(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) issues to fix", comment: "Popover status row, under Needs attention: how many attention rows follow")
        }
    }

    // MARK: - Shortcuts (Addendum C)

    /// What the Shortcuts actions say. Their titles, descriptions and phrases are literals in
    /// `Intents/`: the App Intents metadata is read from the source at build time.
    enum Shortcuts {
        static let notSetUp = LocalizedStringResource(
            "Finish setting up ClipShot first: open it from the menu bar.",
            comment: "Shortcuts action refused: the welcome tour has not been completed yet")
        static let noScreenshots = LocalizedStringResource(
            "No screenshots yet. ClipShot finds the ones taken while it runs.",
            comment: "Shortcuts action: there is no screenshot ClipShot tracks in the screenshot folder")
        static let retentionOff = LocalizedStringResource(
            "Retention is off. Turn it on in ClipShot’s settings to clean up old screenshots.",
            comment: "Clean Up Old Screenshots Now refused: retention (cleanup) is off")
        static let retentionNotConfirmed = LocalizedStringResource(
            "Retention is paused until you check what it would move in ClipShot’s settings.",
            comment: "Clean Up Old Screenshots Now refused: the screenshot folder changed and its preview was not confirmed")
        static let paused = LocalizedStringResource(
            "Copying paused", comment: "Shortcuts: Pause Copying ran; Copy to clipboard is off")
        static let retentionChanged = LocalizedStringResource(
            "Retention changed during the cleanup, so nothing was moved. Try again.",
            comment: "Clean Up Old Screenshots Now: the retention settings changed while it ran")
        static func screenshots(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) screenshots", comment: "Shortcuts: what Get Recent Screenshots got, said by Siri")
        }
        static func screenshotsCutShort(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) screenshots. The others are too large to get at once.",
                comment: "Shortcuts: Get Recent Screenshots stopped at its size limit (512 MB) before it had as many as asked")
        }
    }

    // MARK: - Preview mode macOS: copying waits

    enum ThumbnailWait {
        static let offer = LocalizedStringResource(
            "Copying waits until the macOS thumbnail disappears, about 6 seconds after each screenshot.",
            comment: "One-time popover row after an update, while the macOS floating thumbnail is on: what it costs")
        static let hint = LocalizedStringResource(
            "Copying waits for the macOS thumbnail",
            comment: "Popover status row under Copying on, Preview mode macOS, before a Copy at once link")
        static let useClipShot = LocalizedStringResource(
            "Copy at once", comment: "Button: switches Preview to ClipShot, which turns the macOS thumbnail off")
    }

    // MARK: - Floating preview

    enum Preview {
        static let copied = LocalizedStringResource(
            "Copied", comment: "Badge on ClipShot's floating preview: the screenshot is on the clipboard")
        static let accessibility = LocalizedStringResource(
            "Copied screenshot", comment: "VoiceOver label of the floating preview")
        static let markupHint = LocalizedStringResource(
            "Click to mark it up", comment: "Tooltip and VoiceOver hint: a click opens the screenshot in Markup")
        static let copy = LocalizedStringResource("Copy", comment: "Floating preview menu: copies the screenshot")
        static let editWithMarkup = LocalizedStringResource(
            "Edit with Markup", comment: "Floating preview menu: opens the screenshot in macOS Markup")
        static let close = LocalizedStringResource("Close", comment: "Floating preview: hides it")
        static func extraDisplays(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) more displays in this screenshot",
                comment: "VoiceOver label of the +N chip: a full-screen capture also saved this many other displays")
        }
        static let panel = LocalizedStringResource(
            "Screenshot previews", comment: "VoiceOver label of the floating previews' window")
    }

    // MARK: - Attention rows

    enum Attention {
        static let destinationClipboard = LocalizedStringResource(
            "Screenshots go to the clipboard only, so macOS saves no file and ClipShot has nothing to copy.")
        static let destinationOther = LocalizedStringResource(
            "Screenshots go to another app instead of a file, so ClipShot has nothing to copy.",
            comment: "The macOS screenshot destination is an app such as Preview or Mail")
        static func folderMissing(_ name: String) -> LocalizedStringResource {
            "The screenshot folder “\(name)” was not found."
        }
        static func folderAccessDenied(_ name: String) -> LocalizedStringResource {
            "macOS blocked access to “\(name)”."
        }
        static let couldNotCopy = LocalizedStringResource("ClipShot saw a screenshot but could not copy it.")
        static func retentionFolderChanged(_ name: String) -> LocalizedStringResource {
            "Screenshots now go to “\(name)”. Retention is paused until you check what it would move."
        }
        static func noTrash(_ name: String) -> LocalizedStringResource {
            "“\(name)” has no Trash, so retention is off for it."
        }
        static func more(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource("+\(count) more", comment: "Under the top attention row: how many more there are")
        }
        static let showLess = LocalizedStringResource("Show less", comment: "Collapses the list of attention rows")
    }

    enum Action {
        static let saveToFile = LocalizedStringResource("Save screenshots to a file")
        static let chooseFolder = LocalizedStringResource("Choose folder…")
        static let openPrivacySettings = LocalizedStringResource("Open Privacy Settings")
        static let copyAgain = LocalizedStringResource("Copy again")
        static let report = LocalizedStringResource("Report", comment: "Opens a pre-filled GitHub issue")
        static let review = LocalizedStringResource(
            "Review", comment: "Opens the Retention settings to check the new folder")
        static let showInFinder = LocalizedStringResource("Show in Finder")
        static let dismiss = LocalizedStringResource("Dismiss")
    }

    // MARK: - Latest screenshot

    enum Latest {
        static let none = LocalizedStringResource("No screenshot copied yet")
        static let justNow = LocalizedStringResource(
            "Just now", comment: "Age of a recent screenshot when it is under a minute old")
        /// The one-time Markup tip names what can be clicked in this Preview mode (A4).
        static func markupTip(_ mode: PreviewMode) -> LocalizedStringResource {
            switch mode {
            case .clipShot:
                LocalizedStringResource(
                    "Click the preview, or the picture here, to mark it up; ClipShot copies the edited image.",
                    comment: "One-time tip, Preview mode ClipShot: the floating preview and the popover card's picture open Markup")
            case .macOS:
                LocalizedStringResource(
                    "Click the macOS thumbnail, or the picture here, to mark it up; ClipShot copies the edited image.",
                    comment: "One-time tip, Preview mode macOS: the macOS floating thumbnail and the popover card's picture open Markup")
            case .none:
                LocalizedStringResource(
                    "Click the picture here to mark it up; ClipShot copies the edited image.",
                    comment: "One-time tip, Preview mode None: the popover card's picture opens Markup")
            }
        }
    }

    // MARK: - Recent screenshots and Undo

    enum Recent {
        static let list = LocalizedStringResource(
            "Recent screenshots", comment: "VoiceOver label of the popover's list of recent screenshots, newest first")
        /// "Just now, 1.2 MB, 1 of 4": after the file name, what VoiceOver reads of a row.
        /// The numbers come formatted, as the tour's step counter has them.
        static func rowValue(age: String, size: String, position: Int, count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(age), \(size), \(position.formatted()) of \(count.formatted())",
                comment: "VoiceOver value of a row in the list of recent screenshots: its age, file size, then its place in the list, as in 1 of 4")
        }
        static let moved = LocalizedStringResource(
            "Moved to the Trash", comment: "Popover row for 5 seconds after Move to Trash, before its Undo button")
        static let undo = LocalizedStringResource(
            "Undo", comment: "Puts the screenshot just moved to the Trash back")
        static let putBack = LocalizedStringResource(
            "Put back from the Trash", comment: "VoiceOver announcement after Undo put a screenshot back")
    }

    /// A Move to Trash or Undo that did not happen: said where the user acted, for 5 s.
    enum Failure {
        static let copyFailed = LocalizedStringResource(
            "Not copied: the file is gone or could not be read.",
            comment: "Copy or Copy again failed: the screenshot was moved or deleted meanwhile, ClipShot refused to read it, or the clipboard took nothing")
        static let notTracked = LocalizedStringResource(
            "Not moved: ClipShot only moves screenshots taken while it runs.",
            comment: "Move to Trash refused: ClipShot did not see this screenshot being taken")
        static let outsideFolder = LocalizedStringResource(
            "Not moved: the file is no longer in the screenshot folder.",
            comment: "Move to Trash refused: the file left the screenshot folder")
        static let noTrash = LocalizedStringResource(
            "Not moved: this disk has no Trash.",
            comment: "Move to Trash refused: the volume has no Trash, and ClipShot never deletes")
        static let trashFailed = LocalizedStringResource(
            "Not moved: the file changed, or the Trash refused it.",
            comment: "Move to Trash failed: the file was replaced since, or the system refused the move")
        static let undoFailed = LocalizedStringResource(
            "Not put back: Undo has run out, or another file has its name now.",
            comment: "Undo failed: its 5 seconds are up, or a file with the same name is in its place")
    }

    static let copyToClipboard = LocalizedStringResource("Copy to clipboard")

    // MARK: - Retention summary

    enum Summary {
        static let off = LocalizedStringResource("Retention is off")
        static let paused = LocalizedStringResource("Retention is paused")
        /// The same sentence shape as the tour's period choice (Addendum A7).
        static func olderGo(_ days: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "Older than \(days) days go to the Trash",
                comment: "Popover retention row while retention is on: screenshots older than the period, in days, go to the Trash")
        }
        static let offForFolder = LocalizedStringResource(
            "Retention is off for this folder", comment: "The folder has no Trash, or is a system or home-level folder")
        static let noCleanupYet = LocalizedStringResource(
            "No cleanup needed yet", comment: "Retention is on but has not moved anything so far")
        static func lastCleanupToday(_ time: String, moved: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "Last cleanup today at \(time), \(moved) moved", comment: "Time of day, then how many screenshots went to the Trash")
        }
        static func lastCleanup(_ date: String, moved: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "Last cleanup \(date), \(moved) moved", comment: "Date and time, then how many screenshots went to the Trash")
        }
        static func freed(_ size: String) -> LocalizedStringResource {
            "Freed \(size) since install"
        }
    }

    // MARK: - Update row

    enum Update {
        static let ready = LocalizedStringResource("Update ready")
        static let restart = LocalizedStringResource("Click to restart into the new version")
        static let help = LocalizedStringResource("Installs the downloaded update and relaunches ClipShot.")
        static let unavailableInThisBuild = LocalizedStringResource(
            "updates.unavailableInThisBuild",
            defaultValue: "Updates unavailable in this build.",
            comment: "Shown in Settings when the running copy cannot self-update")
        static let managedByHomebrew = LocalizedStringResource(
            "updates.managedByHomebrew",
            defaultValue: "Updates managed by Homebrew. Run: brew upgrade --cask clipshot",
            comment: "Shown when ClipShot was installed by a Homebrew cask, which owns updates")
        static let check = LocalizedStringResource("Check for Updates…")
        static let checkAutomatically = LocalizedStringResource("Check automatically")
        static let checkAutomaticallyNote = LocalizedStringResource(
            "Downloads updates in the background and offers to restart when one is ready. ClipShot never restarts on its own.")
    }

    // MARK: - Footer

    enum Footer {
        static let openFolder = LocalizedStringResource("Open Screenshots Folder")
        static let settings = LocalizedStringResource("Settings…")
        static let about = LocalizedStringResource("About ClipShot")
        static let quit = LocalizedStringResource("Quit")
    }

    static let aboutDescription = LocalizedStringResource(
        "Copies every screenshot to the clipboard the moment you take it and keeps the file. Can move old screenshots to the Trash.")

    // MARK: - Settings

    enum Tab {
        static let general = LocalizedStringResource("General", comment: "Settings tab")
        static let capture = LocalizedStringResource("Capture", comment: "Settings tab")
        static let retention = LocalizedStringResource("Retention", comment: "Settings tab")
        static let about = LocalizedStringResource("About", comment: "Settings tab with updates, version and links")
    }

    enum General {
        static let startup = LocalizedStringResource("Startup", comment: "Settings section header")
        static let launchAtLogin = LocalizedStringResource("Launch at login")
        static let clipboard = LocalizedStringResource("Clipboard", comment: "Settings section header")
        static let copyNote = LocalizedStringResource(
            "Every new screenshot goes to the clipboard as an image. The file stays where macOS saves it.")
        static let replayTour = LocalizedStringResource("Replay welcome tour")
        static let replayNote = LocalizedStringResource(
            "The tour opens the next time you click ClipShot in the menu bar.",
            comment: "Settings > General, after Replay welcome tour: the tour shows in the popover, not here")
    }

    enum Capture {
        static let notWatching = LocalizedStringResource(
            "ClipShot reads the screenshot settings once the welcome tour is done.")
        static let saveFolder = LocalizedStringResource("Save folder", comment: "Settings section header")
        static let choose = LocalizedStringResource("Choose…", comment: "Picks a folder")
        static let choosePrompt = LocalizedStringResource("Choose", comment: "Default button of the folder picker")
        static let chooseMessage = LocalizedStringResource("Choose where macOS saves screenshots.")
        static let reset = LocalizedStringResource("Reset to macOS default")
        static let recordingsFollow = LocalizedStringResource("Screen recordings go to the same folder.")
        static let notFound = LocalizedStringResource("That folder does not exist.")
        static let notDirectory = LocalizedStringResource("That is not a folder.")
        static let notWritable = LocalizedStringResource("ClipShot cannot write to that folder.")
        static let forbidden = LocalizedStringResource("Choose a folder outside system locations and apps.")
        static let backupFailed = LocalizedStringResource(
            "ClipShot could not back up your screenshot settings, so it changed nothing.",
            comment: "Settings > Capture: the one-time backup of the macOS screenshot settings failed, so no setting was written")
        static func folderError(_ error: FolderValidation) -> LocalizedStringResource {
            switch error {
            case .notFound, .ok: notFound
            case .notDirectory: notDirectory
            case .notWritable: notWritable
            case .forbidden: forbidden
            case .backupFailed: backupFailed
            }
        }
        static let preview = LocalizedStringResource(
            "Preview", comment: "Settings > Capture: what shows after a screenshot (ClipShot, macOS or None)")
        static let previewNone = LocalizedStringResource(
            "None", comment: "Settings > Capture > Preview: no preview at all")
        static func previewNote(_ mode: PreviewMode) -> LocalizedStringResource {
            switch mode {
            case .clipShot:
                LocalizedStringResource(
                    "Copies the moment you take a screenshot and shows ClipShot’s own preview. The macOS thumbnail is off, because it holds the file back a few seconds.",
                    comment: "Settings > Capture > Preview ClipShot")
            case .macOS:
                LocalizedStringResource(
                    "Shows the macOS thumbnail. macOS saves the file, and ClipShot copies it, only when the thumbnail disappears, a few seconds later.",
                    comment: "Settings > Capture > Preview macOS")
            case .none:
                LocalizedStringResource(
                    "Copies the moment you take a screenshot, with no preview.",
                    comment: "Settings > Capture > Preview None")
            }
        }
        static let pdfNote = LocalizedStringResource(
            "Screenshots are set to PDF. While the thumbnail is on, macOS saves no PDF file, so there is nothing to copy.")
        static let appliesNext = LocalizedStringResource(
            "Applies from the next screenshot", comment: "A macOS screenshot setting changed while a screenshot was still being saved")
        static let savedAsFiles = LocalizedStringResource("Screenshots are saved as files.")
        static let restore = LocalizedStringResource("Restore previous settings")
        static let restoreButton = LocalizedStringResource("Restore", comment: "Puts back the macOS screenshot settings")
        static let restoreNote = LocalizedStringResource(
            "Puts back the macOS screenshot settings from before ClipShot first changed them.")
        static let restored = LocalizedStringResource("Restored.")
        static let nothingToRestore = LocalizedStringResource(
            "Nothing to restore: ClipShot has not changed any macOS screenshot setting.")
    }

    enum Retention {
        static let enable = LocalizedStringResource("Move old screenshots to the Trash")
        static let checking = LocalizedStringResource("Checking…")
        static func wouldMove(_ count: Int, _ size: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) screenshots (\(size)) would go to the Trash now", comment: "Retention preview: count, then total size")
        }
        static let nothingWouldMove = LocalizedStringResource("No screenshots would go to the Trash now")
        /// Once retention is on: what the next run moves.
        static func willMove(_ count: Int, _ size: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) screenshots (\(size)) will go to the Trash at the next cleanup",
                comment: "Retention is on: count, then total size, of what the next cleanup moves")
        }
        static let nothingDue = LocalizedStringResource(
            "No screenshots are old enough for the Trash yet", comment: "Retention is on and nothing has expired")
        static let turnOn = LocalizedStringResource("Turn on", comment: "Confirms turning retention on after the preview")
        static let cancel = LocalizedStringResource("Cancel")
        static func broad(_ name: String) -> LocalizedStringResource {
            "ClipShot does not clean up “\(name)”: it is a system or home-level folder."
        }
        static let resume = LocalizedStringResource(
            "Resume for this folder", comment: "Confirms retention for the new screenshot folder")
        static let period = LocalizedStringResource("Keep screenshots for")
        static func days(_ days: Int) -> LocalizedStringResource {
            LocalizedStringResource("\(days) days", comment: "Retention period")
        }
        static let custom = LocalizedStringResource("Custom", comment: "Retention period: any number of days")
        static func skipped(_ count: Int) -> LocalizedStringResource {
            "\(count) files here are not screenshots and are never touched"
        }
        static func pending(_ count: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(count) more wait for the next cleanup", comment: "One cleanup moves at most 500 screenshots")
        }
        static let recordings = LocalizedStringResource("Screen recordings are not touched.")
        static let scope = LocalizedStringResource(
            "Only screenshots taken while ClipShot runs are cleaned up. Rename a screenshot to keep it.")
        static func adoptButton(_ count: Int, _ size: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "Also clean up \(count) older screenshots (\(size))",
                comment: "Screenshots from before ClipShot ran, count then total size")
        }
        static func adoptTitle(_ count: Int, _ size: String) -> LocalizedStringResource {
            "Also clean up \(count) older screenshots (\(size))?"
        }
        static let adoptMessage = LocalizedStringResource(
            "ClipShot did not see these being taken. They go to the Trash with the next cleanup.")
        static let adoptConfirm = LocalizedStringResource("Add to cleanup")
        static let cleanUpNow = LocalizedStringResource("Clean up now")
        static func cleanUpTitle(_ count: Int, _ size: String) -> LocalizedStringResource {
            "Move \(count) screenshots (\(size)) to the Trash?"
        }
        static let cleanUpMessage = LocalizedStringResource("You can put them back from the Trash.")
        static let moveToTrash = LocalizedStringResource("Move to Trash")
        static func moved(_ count: Int, _ size: String) -> LocalizedStringResource {
            "Moved \(count) screenshots (\(size)) to the Trash."
        }
        static let nothingMoved = LocalizedStringResource("Nothing to move.")
        static let showTrash = LocalizedStringResource("Show Trash")
        static let trashNotOpened = LocalizedStringResource(
            "Could not open the Trash. Open it from the Dock.",
            comment: "Settings > Retention, after Show Trash found no Trash it could open")
    }

    // MARK: - Welcome tour

    enum Onboarding {
        static let skip = LocalizedStringResource("Skip", comment: "Welcome tour: ends the tour")
        static let back = LocalizedStringResource("Back", comment: "Welcome tour: previous step")
        static let next = LocalizedStringResource("Next", comment: "Welcome tour: next step")
        static let done = LocalizedStringResource("Done", comment: "Welcome tour: last step's button")
        /// "2 of 3". The numbers come formatted, so no plural is needed.
        static func stepOf(_ step: Int, _ total: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "\(step.formatted()) of \(total.formatted())", comment: "Welcome tour step counter, such as 2 of 3")
        }

        static let welcomeTitle = LocalizedStringResource("Welcome to ClipShot")
        static let welcomeBody = LocalizedStringResource(
            "Every screenshot you take goes to the clipboard the moment you take it, ready to paste. macOS still saves the file as usual.")

        static let folderTitle = LocalizedStringResource(
            "Your screenshot folder", comment: "Welcome tour step 2, before folder access")
        static let folderBody = LocalizedStringResource(
            "ClipShot watches the folder where macOS saves screenshots and copies each new one. If that folder is Desktop, Documents or Downloads, macOS asks you once to allow it.",
            comment: "Welcome tour step 2: explains folder access before the button that asks for it")
        static let startCopying = LocalizedStringResource(
            "Start copying", comment: "Welcome tour step 2: starts watching the screenshot folder")

        static let tryTitle = LocalizedStringResource(
            "Try it: press ⇧⌘4", comment: "Welcome tour step 2, after folder access: take a screenshot")
        /// What Try it says about timing and Markup, in the Preview mode that applies.
        static func tryBody(_ mode: PreviewMode) -> LocalizedStringResource {
            switch mode {
            case .clipShot:
                LocalizedStringResource(
                    "Paste at once: ClipShot shows its own preview instead of the macOS thumbnail, which holds the file back a few seconds. Click the preview to mark it up.",
                    comment: "Welcome tour step 2, Preview mode ClipShot: the trade-off in one sentence, then the Markup flow")
            case .macOS:
                LocalizedStringResource(
                    "Paste works once the floating thumbnail disappears. Click the thumbnail to mark it up first: ClipShot copies the edited image.",
                    comment: "Welcome tour step 2, Preview mode macOS: thumbnail timing and the Markup flow")
            case .none:
                LocalizedStringResource(
                    "Paste at once: the macOS thumbnail, which holds the file back a few seconds, is off.",
                    comment: "Welcome tour step 2, Preview mode None: the trade-off in one sentence")
            }
        }
        static let waiting = LocalizedStringResource(
            "Waiting for a screenshot…", comment: "Welcome tour step 2: no screenshot copied yet")
        static let watchMenuBar = LocalizedStringResource(
            "Watch the menu bar",
            comment: "Welcome tour step 2, under Waiting for a screenshot: ClipShot's menu bar icon confirms each copy")
        static let copied = LocalizedStringResource(
            "Copied. Paste it anywhere with ⌘V.", comment: "Welcome tour step 2: the first screenshot is on the clipboard")

        static let paused = LocalizedStringResource(
            "Copying is off, so nothing reaches the clipboard.",
            comment: "Welcome tour step 2: the Copy to clipboard switch is off")
        static let turnOnCopying = LocalizedStringResource(
            "Turn on copying", comment: "Welcome tour step 2: switches Copy to clipboard back on")

        static let tidyTitle = LocalizedStringResource(
            "Keep the folder tidy", comment: "Welcome tour step 3: retention offer")
        static let tidyBody = LocalizedStringResource(
            "ClipShot can move the screenshots it saw being made to the Trash. Rename one to keep it.",
            comment: "Welcome tour step 3: what retention does; the period is chosen below")
        /// "Move screenshots older than [30 days] to the Trash": `period` is the choice the
        /// sentence shows as a pop-up link, such as "30 days". A `Text`, so the link keeps its
        /// own attributes inside the translated sentence. (Catalog comment: welcome tour step
        /// 3, beside the retention switch; the period is a pop-up choice.)
        static func tidyPeriod(_ period: Text) -> Text {
            let sentence: LocalizedStringKey = "Move screenshots older than \(period) to the Trash"
            return Text(sentence)
        }
    }

    enum About {
        static func version(_ short: String, _ build: String) -> LocalizedStringResource {
            "Version \(short) (\(build))"
        }
        static func copied(_ count: Int) -> LocalizedStringResource {
            "\(count) screenshots copied"
        }
        static func freed(_ size: String) -> LocalizedStringResource {
            LocalizedStringResource("\(size) freed by cleanup", comment: "Total size moved to the Trash")
        }
        static let sourceCode = LocalizedStringResource("Source code")
        static let moreApps = LocalizedStringResource("More apps")
    }
}
