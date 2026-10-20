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
        Self.wait { self.model.recent.first?.url.lastPathComponent == DemoContent.screenshotName }
    }

    /// Earlier screenshots ClipShot saw being taken, for the popover's list: in the ledger,
    /// minutes to two days old, each picture in its own colours. More than the list shows
    /// under the current one, so it fills up again after a move to the Trash.
    func recentScreenshots() async throws {
        let ages: [TimeInterval] = [6 * 60, 48 * 60, 3 * 3_600, 26 * 3_600, 50 * 3_600]
        var files: [CaptureFile] = []
        for (index, age) in ages.enumerated() {
            let name = DemoContent.recentScreenshotName(index)
            files.append(try shoot(name, image: DemoContent.screenshotPNG(variant: index + 1), age: age))
        }
        for file in files { await ledger.record(file) }
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
        // `-key YES` arrives as a string; Preferences reads booleans as Bool. Only the
        // spellings of a boolean: "1" or "0" may be a number (a retention period of 1 day).
        return Self.coerced(arguments[key])
    }

    /// The launch argument as Preferences reads it: YES/NO and true/false become Bool,
    /// anything else stays as it arrived.
    static func coerced(_ value: Any?) -> Any? {
        switch value as? String {
        case "YES", "true": true
        case "NO", "false": false
        default: value
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
    func open(_ url: URL) -> Bool { true }
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

    static func recentScreenshotName(_ index: Int) -> String {
        let times = ["09.35.40", "08.53.17", "06.41.02", "07.12.55", "07.48.30"]
        let day = ["2026-10-19", "2026-10-19", "2026-10-19", "2026-10-18", "2026-10-17"][index % 5]
        return "\(screenshotPrefix) \(day) \(screenshotTime(times[index % times.count])).png"
    }

    static func oldScreenshotName(days: Int) -> String {
        let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: fixedDate) ?? fixedDate
        let day = date.formatted(.iso8601.year().month().day())
        return "\(screenshotPrefix) \(day) \(screenshotTime("14.\(String(format: "%02d", 10 + days % 50)).05")).png"
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_792_400_000)

    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

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

    /// `time` is "HH.mm.ss". English renders run on a 12-hour clock (`scripts/screenshots.sh`),
    /// where macOS writes "9.41.12 AM" with a narrow no-break space before the AM.
    static func screenshotTime(_ time: String, language: String = language) -> String {
        let trimmed = time.hasPrefix("0") ? String(time.dropFirst()) : time
        switch language {
        case "sk": return "o \(trimmed)"
        case "cs": return "v \(trimmed)"
        case "de": return "um \(time)"
        case "es": return "a las \(trimmed)"
        case "fr": return "à \(time)"
        default:
            let parts = time.split(separator: ".")
            guard parts.count == 3, let hour = Int(parts[0]) else { return "at \(time)" }
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return "at \(twelve).\(parts[1]).\(parts[2])\u{202F}\(hour < 12 ? "AM" : "PM")"
        }
    }

    /// The "now" the pictures are drawn at: today at 15:00, whatever the time of rendering.
    /// The popover reads its dates against it (`displayNow`), so "Last cleanup today at 9:12"
    /// reads the same at 5 in the morning. File ages stay real: the copy pipeline needs them.
    static let renderNow: Date = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: Date()) ?? Date()

    /// When the popover's "Last cleanup" happened: today at 09:12, or yesterday at 09:12 when
    /// that is not at least ten minutes ago, so the picture never shows a cleanup still to
    /// come and does not change with the minute it is rendered.
    static func lastCleanup(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: 9, minute: 12, second: 0, of: now) ?? now
        if today <= now.addingTimeInterval(-10 * 60) { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    /// An invented app window with a chart and cards: shapes only, so it reads the same in
    /// every language and shows nothing personal.
    static let screenshotPNG: Data = screenshotPNG(variant: 0)

    /// The demo window in other colours, so the list's pictures tell apart; `dark`, as a
    /// window in dark mode.
    static func screenshotPNG(variant: Int, dark: Bool = false) -> Data {
        let renderer = ImageRenderer(content: DemoWindow(variant: variant, dark: dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }
}

private struct DemoWindow: View {
    var variant = 0
    var dark = false

    /// A grey of the light window, or its counterpart in dark mode.
    private func grey(_ white: Double) -> Color { Color(white: dark ? 1.1 - white : white) }

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.937, green: 0.396, blue: 0.329), Color(red: 0.973, green: 0.643, blue: 0.247)),
        (Color(red: 0.247, green: 0.459, blue: 0.937), Color(red: 0.400, green: 0.780, blue: 0.960)),
        (Color(red: 0.196, green: 0.667, blue: 0.455), Color(red: 0.600, green: 0.850, blue: 0.400)),
        (Color(red: 0.557, green: 0.329, blue: 0.890), Color(red: 0.890, green: 0.490, blue: 0.820)),
        (Color(red: 0.180, green: 0.560, blue: 0.640), Color(red: 0.980, green: 0.780, blue: 0.300)),
        (Color(red: 0.420, green: 0.440, blue: 0.500), Color(red: 0.950, green: 0.420, blue: 0.560)),
    ]
    private let bars: [CGFloat] = [0.42, 0.58, 0.51, 0.72, 0.66, 0.84, 0.78, 0.93]
    private var coral: Color { Self.palettes[variant % Self.palettes.count].0 }
    private var amber: Color { Self.palettes[variant % Self.palettes.count].1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 14, height: 14) }
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(grey(0.94))

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(0..<6) { index in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == 1 ? coral.opacity(0.25) : grey(0.9))
                            .frame(width: 180, height: 26)
                    }
                }
                VStack(alignment: .leading, spacing: 24) {
                    RoundedRectangle(cornerRadius: 6).fill(grey(0.82)).frame(width: 320, height: 30)
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
                                .fill(grey(index == 0 ? 0.88 : 0.93))
                                .frame(width: 236, height: 150)
                        }
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(grey(1))
        }
        .frame(width: 1280, height: 820)
    }
}
#endif
