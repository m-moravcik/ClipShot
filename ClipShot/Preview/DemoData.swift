#if DEBUG
import AppKit
import Combine
import SwiftUI
import Synchronization

/// A real `AppModel` on invented data, for the screenshot harness.
///
/// Everything the model reaches outside the process is swapped for something that stays in
/// a throwaway directory: the screenshot folder and its home live under the temporary
/// directory, `com.apple.screencapture` is a dictionary, the pasteboard only says yes or no,
/// the Trash is never touched, and no login item, sound, announcement or update check runs.
/// The copy pipeline itself is real: a demo screenshot is written into the folder with the
/// markers macOS sets, and the model sees, copies and shows it as it would a real one.
@MainActor
final class DemoScene {
    let home: URL
    let folder: URL
    let prefs: DemoScreencapturePreferences
    let preferences: Preferences
    let pasteboard = DemoPasteboard()
    let ledger: ScreenshotLedger
    let model: AppModel
    private let staging: URL

    /// `hasTrash: false` gives the folder a volume without a Trash, for that attention.
    init(in root: URL, onboardingShown: Bool = true, hasTrash: Bool = true) throws {
        let fm = FileManager.default
        let base = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = base.appendingPathComponent("Home", isDirectory: true)
        folder = home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        staging = base.appendingPathComponent("Staging", isDirectory: true)
        let support = base.appendingPathComponent("Support", isDirectory: true)
        for dir in [folder, staging, support] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        prefs = DemoScreencapturePreferences(["location": folder.path, "target": "file"])
        preferences = Preferences(store: DemoPreferenceStore())
        preferences.onboardingShown = onboardingShown
        if onboardingShown {
            // A current install in Preview mode ClipShot; a fresh one applies it in the tour.
            preferences.previewModeApplied = true
            prefs["show-thumbnail"] = false
        }
        if !onboardingShown {
            // A fresh install: nothing chosen yet, whatever the launch arguments say.
            preferences.launchAtLoginIntent = nil
            preferences.firstCopyDone = false
        }
        let logFile = support.appendingPathComponent("clipshot.log")
        let log = Log(fileURL: logFile)
        ledger = ScreenshotLedger(fileURL: support.appendingPathComponent("ledger.json"), log: log)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        let never = Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()
        model = AppModel(dependencies: AppDependencies(
            preferences: preferences,
            screencapturePrefs: prefs,
            backup: PrefsBackup(fileURL: support.appendingPathComponent("prefs-backup.plist")),
            home: home,
            events: DirectoryEventSource(),
            pasteboard: pasteboard,
            ledger: ledger,
            trasher: DemoTrasher(),
            hasTrash: { _ in hasTrash },
            clock: { Date() },
            pollInterval: .milliseconds(100),
            statusInterval: .milliseconds(200),
            hourly: never,
            wake: never,
            makeFlashTimer: { _, _, _ in DemoFlashTimer() },
            reduceMotion: { false },
            playSound: {},
            announce: { _ in },
            workspace: DemoWorkspace(),
            screencaptureUIRunning: { false },
            reconcileLoginItem: { $0 ?? false },
            setLoginItem: { _ in true },
            log: log,
            logFile: logFile,
            appVersion: version,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            // Previews stay while the harness draws them; no panel ever opens.
            previewLifetime: .seconds(3_600)))
    }

    /// Starts watching and waits until the folder is watched (or the watch has failed).
    @discardableResult
    func start() -> Bool {
        model.startWatching()
        return Self.wait { self.model.watchedFolder != nil || !self.model.attentions.isEmpty }
    }

    func stop() {
        model.stopWatching()
    }

    /// Writes a screenshot the way `screencaptureui` does: into a staging directory with the
    /// capture markers, then renamed into the folder.
    @discardableResult
    func shoot(_ name: String, image: Data, age: TimeInterval = 0, into target: URL? = nil) throws -> CaptureFile {
        let staged = staging.appendingPathComponent("\(UUID().uuidString).png")
        try image.write(to: staged)
        Self.setxattr(CaptureMarker.captureFlag, Self.bplist(true), on: staged)
        Self.setxattr(CaptureMarker.captureType, Self.bplist("selection"), on: staged)
        if age > 0 {
            let date = Date().addingTimeInterval(-age)
            try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: staged.path)
        }
        let url = (target ?? folder).appendingPathComponent(name)
        guard rename(staged.path, url.path) == 0, let file = CaptureFile.inspect(url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }

    /// Writes the demo screenshot and waits until the popover's card shows it.
    func copyDemoScreenshot() throws {
        _ = try shoot(DemoContent.screenshotName, image: DemoContent.screenshotPNG)
        Self.wait { self.model.latest != nil }
    }

    /// Old screenshots, `count` of them `days` old: in the ledger when `tracked`, otherwise
    /// left for "Also clean up N older screenshots".
    func oldScreenshots(_ count: Int, days: Int, tracked: Bool) async throws {
        var files: [CaptureFile] = []
        for index in 0..<count {
            let name = DemoContent.oldScreenshotName(days: days + index)
            files.append(try shoot(name, image: DemoContent.screenshotPNG, age: TimeInterval(days + index) * 86_400))
        }
        if tracked { await ledger.adopt(files) }
    }

    /// Turns the main run loop until `condition` holds or `timeout` passes. The model's work
    /// runs on the main actor, so it moves on while this waits.
    @discardableResult
    static func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }

    /// Turns the run loop for `seconds`, for work that has no condition to wait for.
    static func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func bplist(_ value: Any) -> Data {
        (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)) ?? Data()
    }

    private static func setxattr(_ name: String, _ data: Data, on url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { Darwin.setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
    }
}

/// Reads the launch-argument domain only (the values `scripts/screenshots.sh` passes) and
/// keeps every write in memory, so a harness run neither depends on nor changes the Debug
/// build's stored preferences.
final class DemoPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]
    private var cleared: Set<String> = []
    private let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)

    func object(forKey key: String) -> Any? {
        if let value = values[key] { return value }
        if cleared.contains(key) { return nil }
        // `-key YES` arrives as a string; Preferences reads booleans as Bool.
        switch arguments[key] as? String {
        case "YES", "true", "1": return true
        case "NO", "false", "0": return false
        default: return arguments[key]
        }
    }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            values[key] = value
            cleared.remove(key)
        } else {
            values[key] = nil
            cleared.insert(key)
        }
    }
}

/// `com.apple.screencapture` as a dictionary.
final class DemoScreencapturePreferences: ScreencapturePreferences {
    /// Property-list values only (String, Bool, Int), so crossing the lock is safe.
    private struct Box: @unchecked Sendable { var value: Any? }

    private let values: Mutex<[String: Box]>

    init(_ initial: [String: Any]) {
        values = Mutex(initial.mapValues { Box(value: $0) })
    }

    subscript(key: String) -> Any? {
        get { value(forKey: key) }
        set { set(newValue, forKey: key) }
    }

    func value(forKey key: String) -> Any? { values.withLock { $0[key]?.value } }
    func set(_ value: Any?, forKey key: String) { values.withLock { $0[key] = value.map { Box(value: $0) } } }
    func synchronize() {}
}

/// Says whether the copy worked; never touches the real pasteboard.
@MainActor
final class DemoPasteboard: PasteboardWriting {
    var failing = false
    let changeCount = 0
    func writePNG(_ data: Data) -> Bool { !failing }
}

/// Refuses every move, so nothing can reach the Trash.
struct DemoTrasher: Trashing {
    func trash(_ url: URL) throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor
final class DemoWorkspace: WorkspaceActions {
    func reveal(_ url: URL) {}
    func open(_ url: URL) {}
}

/// Never ticks: the harness draws the flash phases itself.
@MainActor
final class DemoFlashTimer: FlashTimer {
    func invalidate() {}
}

/// Updates switched on, as a released build has them, without Sparkle.
@MainActor
final class DemoUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates = true
    let isAvailable = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus()
    func checkForUpdates() {}
    func installUpdate() {}
}

/// The pictures and names the demo uses.
@MainActor
enum DemoContent {
    /// What macOS names a screenshot in each language. File names are user data, not UI copy,
    /// so they are not in the String Catalog.
    static var screenshotName: String {
        "\(screenshotPrefix) 2026-10-19 \(screenshotTime("09.41.12")).png"
    }

    static func oldScreenshotName(days: Int) -> String {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: fixedDate) ?? fixedDate
        let day = date.formatted(.iso8601.year().month().day())
        return "\(screenshotPrefix) \(day) \(screenshotTime("14.\(String(format: "%02d", 10 + days % 50)).05")).png"
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_792_400_000)

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static var screenshotPrefix: String {
        switch language {
        case "sk": "Snímka obrazovky"
        case "cs": "Snímek obrazovky"
        case "de": "Bildschirmfoto"
        case "es": "Captura de pantalla"
        case "fr": "Capture d’écran"
        default: "Screenshot"
        }
    }

    private static func screenshotTime(_ time: String) -> String {
        let trimmed = time.hasPrefix("0") ? String(time.dropFirst()) : time
        switch language {
        case "sk": return "o \(trimmed)"
        case "cs": return "v \(trimmed)"
        case "de": return "um \(time)"
        case "es": return "a las \(trimmed)"
        case "fr": return "à \(time)"
        default: return "at \(time)"
        }
    }

    /// An invented app window with a chart and cards: shapes only, so it reads the same in
    /// every language and shows nothing personal.
    static let screenshotPNG: Data = {
        let renderer = ImageRenderer(content: DemoWindow())
        renderer.scale = 1
        guard let image = renderer.cgImage else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }()
}

private struct DemoWindow: View {
    private let bars: [CGFloat] = [0.42, 0.58, 0.51, 0.72, 0.66, 0.84, 0.78, 0.93]
    private let coral = Color(red: 0.937, green: 0.396, blue: 0.329)
    private let amber = Color(red: 0.973, green: 0.643, blue: 0.247)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 14, height: 14) }
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Color(white: 0.94))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<6) { index in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == 1 ? coral.opacity(0.25) : Color(white: 0.9))
                            .frame(width: 180, height: 26)
                    }
                }
                VStack(alignment: .leading, spacing: 24) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.82)).frame(width: 320, height: 30)
                    HStack(alignment: .bottom, spacing: 22) {
                        ForEach(bars.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: [amber, coral], startPoint: .bottom, endPoint: .top))
                                .frame(width: 70, height: 420 * bars[index])
                        }
                    }
                    .frame(height: 420, alignment: .bottom)
                    HStack(spacing: 22) {
                        ForEach(0..<3) { index in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(white: index == 0 ? 0.88 : 0.93))
                                .frame(width: 236, height: 150)
                        }
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
        }
        .frame(width: 1280, height: 820)
    }
}
#endif
