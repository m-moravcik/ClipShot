import Foundation

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
        static let firstCopyHint = LocalizedStringResource(
            "Paste works once the thumbnail disappears",
            comment: "Popover hint until the first copy: macOS saves the file when its floating thumbnail goes away")
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
            "Just now", comment: "Age of the latest screenshot when it is under a minute old")
        /// "Latest screenshot, 2 minutes ago, 1.2 MB".
        static func accessibility(age: String, size: String) -> LocalizedStringResource {
            LocalizedStringResource(
                "Latest screenshot, \(age), \(size)", comment: "VoiceOver label of the thumbnail: age, then file size")
        }
        static let markupTip = LocalizedStringResource(
            "Click the thumbnail to annotate with Markup; ClipShot copies the edited image.",
            comment: "One-time tip: the floating thumbnail macOS shows after a screenshot")
    }

    static let copyToClipboard = LocalizedStringResource("Copy to clipboard")

    // MARK: - Retention summary

    enum Summary {
        static let off = LocalizedStringResource("Retention is off")
        static let paused = LocalizedStringResource("Retention is paused")
        static func keeps(_ days: Int) -> LocalizedStringResource {
            LocalizedStringResource("Keeps \(days) days", comment: "Retention keeps screenshots this many days")
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
        "Copies every screenshot to the clipboard and keeps the file and the thumbnail. Can move old screenshots to the Trash.")

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
        static let copySound = LocalizedStringResource("Play a sound when copied")
        static let copySoundNote = LocalizedStringResource("The menu bar icon shows every copy, with or without the sound.")
        static let replayTour = LocalizedStringResource("Replay welcome tour")
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
        static func folderError(_ error: FolderValidation) -> LocalizedStringResource {
            switch error {
            case .notFound, .ok: notFound
            case .notDirectory: notDirectory
            case .notWritable: notWritable
            case .forbidden: forbidden
            }
        }
        static let showThumbnail = LocalizedStringResource("Show floating thumbnail")
        static let thumbnailNote = LocalizedStringResource(
            "Off: the file, and so the clipboard, is ready at once. On: macOS saves the file when the thumbnail disappears, a few seconds later.")
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
            "Every screenshot you take goes to the clipboard, ready to paste. macOS still saves the file and shows the thumbnail as usual.")

        static let folderTitle = LocalizedStringResource(
            "Your screenshot folder", comment: "Welcome tour step 2, before folder access")
        static let folderBody = LocalizedStringResource(
            "ClipShot watches the folder where macOS saves screenshots and copies each new one. If that folder is Desktop, Documents or Downloads, macOS asks you once to allow it.",
            comment: "Welcome tour step 2: explains folder access before the button that asks for it")
        static let startCopying = LocalizedStringResource(
            "Start copying", comment: "Welcome tour step 2: starts watching the screenshot folder")

        static let tryTitle = LocalizedStringResource(
            "Try it: press ⇧⌘4", comment: "Welcome tour step 2, after folder access: take a screenshot")
        static let tryBody = LocalizedStringResource(
            "Paste works once the floating thumbnail disappears. Click the thumbnail to mark it up first: ClipShot copies the edited image.",
            comment: "Welcome tour step 2: thumbnail timing and the Markup flow")
        static let waiting = LocalizedStringResource(
            "Waiting for a screenshot…", comment: "Welcome tour step 2: no screenshot copied yet")
        static let copied = LocalizedStringResource(
            "Copied. Paste it anywhere with ⌘V.", comment: "Welcome tour step 2: the first screenshot is on the clipboard")

        static let tidyTitle = LocalizedStringResource(
            "Keep the folder tidy", comment: "Welcome tour step 3: retention offer")
        static func tidyBody(_ days: Int) -> LocalizedStringResource {
            LocalizedStringResource(
                "ClipShot can move the screenshots it saw being made to the Trash after \(days) days. Rename one to keep it.",
                comment: "Welcome tour step 3: the retention period in days")
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
