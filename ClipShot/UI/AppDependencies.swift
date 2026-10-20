import Accessibility
import AppKit
import Combine

/// The repeating timer that drives the copied flash.
@MainActor
protocol FlashTimer: AnyObject {
    func invalidate()
}

/// A main-run-loop `Timer`, in the common modes so it also ticks while a menu is tracking.
@MainActor
final class SystemFlashTimer: FlashTimer {
    private var timer: Timer?

    init(interval: TimeInterval, tolerance: TimeInterval, tick: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }

    /// A timer released without `invalidate()` must not keep ticking on the run loop.
    isolated deinit {
        timer?.invalidate()
    }
}

/// Finder and the default apps.
@MainActor
protocol WorkspaceActions: AnyObject {
    func reveal(_ url: URL)
    /// False when no app could open `url`.
    @discardableResult
    func open(_ url: URL) -> Bool
}

@MainActor
final class SystemWorkspace: WorkspaceActions {
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @discardableResult
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

/// Everything the model reaches outside the process through. `live()` for the app; tests
/// pass fakes. Building one has no side effects.
struct AppDependencies {
    typealias MakeFlashTimer = @MainActor (
        _ interval: TimeInterval, _ tolerance: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void
    ) -> any FlashTimer
    /// The Trash for files on the volume of `folder`; nil `folder` is the home Trash. nil
    /// when there is none. Called off the main actor.
    typealias LocateTrash = @Sendable (_ folder: URL?) -> URL?

    static let systemTrash: LocateTrash = { folder in
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false)
    }

    var preferences: Preferences
    var screencapturePrefs: any ScreencapturePreferences
    var backup: PrefsBackup
    var home: URL
    var events: any FolderEventSource
    var pasteboard: any PasteboardWriting
    var ledger: ScreenshotLedger
    var trasher: any Trashing
    var hasTrash: FolderGuard.TrashLookup
    var clock: @Sendable () -> Date
    var pollInterval: Duration
    /// How often the destination, the folder pref and the retention status are re-read.
    var statusInterval: Duration
    var hourly: AnyPublisher<Void, Never>
    var wake: AnyPublisher<Void, Never>
    var makeFlashTimer: MakeFlashTimer
    var reduceMotion: @MainActor () -> Bool
    var playSound: @MainActor () -> Void
    var announce: @MainActor (LocalizedStringResource) -> Void
    var workspace: any WorkspaceActions
    /// Whether the per-capture `screencaptureui` process is alive; a native setting written
    /// meanwhile applies from the next screenshot (spike F10).
    var screencaptureUIRunning: @MainActor () -> Bool
    /// `LoginItem.reconcile`: takes the stored intent, returns the intent to store.
    var reconcileLoginItem: @MainActor (Bool?) -> Bool
    var setLoginItem: @MainActor (Bool) -> Bool
    var log: Log
    var logFile: URL
    var appVersion: String
    var osVersion: String
    /// Screenshots open in Markup, shared with the copy coordinator (Addendum A4).
    var edits = EditSession()
    /// Hosts the floating previews on screen; nil for none (tests and the screenshot harness).
    /// Called once, when watching starts.
    var makePreviewHost: @MainActor (AppModel) -> AnyObject? = { _ in nil }
    /// Opens a file in Markup and reports how the edit ended.
    var openMarkup: @MainActor (URL, @escaping @MainActor (MarkupResult) -> Void) -> Void = { _, done in done(.failed) }
    /// How long a floating preview stays.
    var previewLifetime: Duration = FloatingPreviews.defaultLifetime
    /// How long Undo is offered after a move to the Trash (Addendum A6).
    var undoLifetime: Duration = AppModel.defaultUndoLifetime
    /// Where Show Trash looks for the Trash.
    var locateTrash: LocateTrash = systemTrash

    @MainActor
    static func live() -> AppDependencies {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/ClipShot", isDirectory: true)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let markup = MarkupOpener()
        var dependencies = AppDependencies(
            preferences: Preferences(),
            screencapturePrefs: SystemScreencapturePreferences(),
            backup: PrefsBackup(fileURL: support.appendingPathComponent("prefs-backup.plist")),
            home: home,
            events: DirectoryEventSource(),
            pasteboard: SystemPasteboard(),
            ledger: .default,
            trasher: FileManagerTrasher(),
            hasTrash: FolderGuard.systemTrashLookup,
            clock: { Date() },
            pollInterval: .seconds(1),
            statusInterval: .seconds(5),
            hourly: RetentionScheduler.hourlyTimer(),
            wake: RetentionScheduler.wakeNotifications(),
            makeFlashTimer: { SystemFlashTimer(interval: $0, tolerance: $1, tick: $2) },
            reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
            playSound: { _ = NSSound(named: "Pop")?.play() },
            announce: { AccessibilityNotification.Announcement(String(localized: $0)).post() },
            workspace: SystemWorkspace(),
            screencaptureUIRunning: { ScreencaptureUI.isRunning() },
            reconcileLoginItem: { LoginItem.reconcile(storedIntent: $0) },
            setLoginItem: { LoginItem.setEnabled($0) },
            log: .shared,
            logFile: Log.defaultFileURL,
            appVersion: version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        dependencies.makePreviewHost = { PreviewPanelController(model: $0) }
        dependencies.openMarkup = { markup.open($0, completion: $1) }
        return dependencies
    }
}
