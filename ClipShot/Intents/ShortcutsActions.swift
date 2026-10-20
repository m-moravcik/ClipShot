import AppIntents
import Foundation
import UniformTypeIdentifiers

// Shortcuts actions (Addendum C). Each runs in the app's own process, on the main actor,
// without opening a window (`supportedModes = .background`); if ClipShot is not running, the
// system launches it in the background first. The logic is the model's
// (`AppModel+Shortcuts.swift`), on the same paths as the popover and Settings; these types
// only map it to App Intents.
//
// Titles, descriptions and parameter names are literals here, not `Copy` constants: the App
// Intents metadata is read from the source at build time. They are keys of
// Localizable.xcstrings like every other string; the phrases are in AppShortcuts.xcstrings.

/// Where the actions find the app's model. Set once at launch; nil under XCTest, the
/// screenshot harness and the probes, where no action can run.
@MainActor
enum IntentHost {
    static weak var model: AppModel?

    static func current() throws(ShortcutError) -> AppModel {
        guard let model else { throw .notSetUp }
        return model
    }
}

extension ShortcutError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { message }
}

extension ShortcutFile {
    var intentFile: IntentFile {
        IntentFile(data: data, filename: name, type: UTType(filenameExtension: fileExtension))
    }
}

struct GetLatestScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Screenshot"
    static let description = IntentDescription(
        "Gets the newest screenshot ClipShot saw being taken in your screenshot folder.",
        resultValueName: "Screenshot")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let files = try await IntentHost.current().shortcutScreenshots(count: 1)
        return .result(value: files[0].intentFile)
    }
}

struct GetRecentScreenshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Screenshots"
    static let description = IntentDescription(
        "Gets the newest screenshots ClipShot saw being taken in your screenshot folder, newest first.",
        resultValueName: "Screenshots")
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Number of Screenshots", description: "How many screenshots to get, from 1 to 10.",
        default: 1, inclusiveRange: (1, 10))
    var count: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$count) recent screenshots")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let files = try await IntentHost.current().shortcutScreenshots(count: count)
        return .result(value: files.map(\.intentFile))
    }
}

struct CopyLatestScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Screenshot"
    static let description = IntentDescription(
        "Copies the newest screenshot to the clipboard as an image, also while copying is paused.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentHost.current().shortcutCopyLatest()
        return .result(dialog: IntentDialog(Copy.screenshotCopied))
    }
}

struct PauseCopyingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Copying"
    static let description = IntentDescription(
        "Stops copying new screenshots to the clipboard, as the Copy to clipboard switch does.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentHost.current().shortcutSetCopying(false)
        return .result(dialog: IntentDialog(Copy.Shortcuts.paused))
    }
}

struct ResumeCopyingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Copying"
    static let description = IntentDescription(
        "Copies new screenshots to the clipboard again, as the Copy to clipboard switch does.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try IntentHost.current().shortcutSetCopying(true)
        return .result(dialog: IntentDialog(Copy.Header.on))
    }
}

struct CleanUpOldScreenshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean Up Old Screenshots Now"
    static let description = IntentDescription(
        "Moves screenshots older than your retention period to the Trash now, as Clean up now in Settings does. Returns how many were moved.",
        resultValueName: "Number of Screenshots")
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Preview Only", description: "Counts what would go to the Trash without moving anything.",
        default: false)
    var previewOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Clean up old screenshots now") {
            \.$previewOnly
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let report = try await IntentHost.current().shortcutCleanUp(previewOnly: previewOnly)
        let size = report.bytes.formatted(.byteCount(style: .file))
        let dialog: LocalizedStringResource = switch (report.previewOnly, report.count) {
        case (true, 0): Copy.Retention.nothingWouldMove
        case (true, let count): Copy.Retention.wouldMove(count, size)
        case (false, 0): Copy.Retention.nothingMoved
        case (false, let count): Copy.Retention.moved(count, size)
        }
        return .result(value: report.count, dialog: IntentDialog(dialog))
    }
}

/// The Focus filter: "Pause copying" while the chosen Focus is on. Off by default, because the
/// system hands a filter its default values when the Focus ends.
struct CopyingFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Copying During Focus"
    static let description: IntentDescription? = IntentDescription(
        "Pauses copying screenshots to the clipboard while this Focus is on. A pause or resume you set yourself meanwhile is kept.")

    @Parameter(title: "Pause copying", default: false)
    var pauseCopying: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: pauseCopying ? "Pause copying" : "Copy as usual")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentHost.current().shortcutFocusChanged(pausing: pauseCopying)
        return .result()
    }
}

/// Phrases for Siri, Spotlight and the Shortcuts app; translated in AppShortcuts.xcstrings.
struct ClipShotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyLatestScreenshotIntent(),
            phrases: [
                "Copy the latest screenshot with \(.applicationName)",
                "\(.applicationName), copy the latest screenshot",
            ],
            shortTitle: "Copy Latest Screenshot", systemImageName: "doc.on.clipboard")
        AppShortcut(
            intent: GetLatestScreenshotIntent(),
            phrases: [
                "Get the latest screenshot from \(.applicationName)",
                "Get my last screenshot from \(.applicationName)",
            ],
            shortTitle: "Get Latest Screenshot", systemImageName: "photo")
        AppShortcut(
            intent: PauseCopyingIntent(),
            phrases: [
                "Pause copying in \(.applicationName)",
                "Pause \(.applicationName)",
            ],
            shortTitle: "Pause Copying", systemImageName: "pause.circle")
        AppShortcut(
            intent: ResumeCopyingIntent(),
            phrases: [
                "Resume copying in \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume Copying", systemImageName: "play.circle")
        AppShortcut(
            intent: CleanUpOldScreenshotsIntent(),
            phrases: [
                "Clean up old screenshots with \(.applicationName)",
                "Clean up screenshots in \(.applicationName)",
            ],
            shortTitle: "Clean Up Old Screenshots", systemImageName: "trash")
    }
}
