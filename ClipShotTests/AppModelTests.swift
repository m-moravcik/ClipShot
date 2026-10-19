import Combine
import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// Counts starts so a test can prove the folder was not touched.
final class CountingEventSource: FolderEventSource {
    private let inner = DirectoryEventSource()
    private let count = Mutex(0)

    var starts: Int { count.withLock { $0 } }

    func start(_ folder: URL, onEvent: @escaping @Sendable () -> Void) throws(WatchError) {
        count.withLock { $0 += 1 }
        try inner.start(folder, onEvent: onEvent)
    }

    func stop() { inner.stop() }
}

@MainActor
final class ManualFlashTimer: FlashTimer {
    let interval: TimeInterval
    let tolerance: TimeInterval
    private let tick: @MainActor () -> Void
    private(set) var invalidated = false

    init(interval: TimeInterval, tolerance: TimeInterval, tick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.tolerance = tolerance
        self.tick = tick
    }

    func invalidate() { invalidated = true }

    func fire(_ times: Int = 1) {
        for _ in 0..<times where !invalidated { tick() }
    }
}

@MainActor
final class RecordingWorkspace: WorkspaceActions {
    private(set) var revealed: [URL] = []
    private(set) var opened: [URL] = []
    func reveal(_ url: URL) { revealed.append(url) }
    func open(_ url: URL) { opened.append(url) }
}

@MainActor
final class WeakModel {
    weak var value: AppModel?
}

@MainActor
final class TickCounter {
    var count = 0
}

/// An AppModel on a temp home with fakes for everything that reaches outside the process.
@MainActor
final class ModelHarness {
    let home: URL
    let folder: URL
    let prefs: FakeScreencapturePreferences
    let preferences: Preferences
    let events = CountingEventSource()
    let pasteboard = RecordingPasteboard()
    let ledger: ScreenshotLedger
    let trasher: FakeTrasher
    let hourly = PassthroughSubject<Void, Never>()
    let wake = PassthroughSubject<Void, Never>()
    let workspace = RecordingWorkspace()
    let logFile: URL
    private(set) var timers: [ManualFlashTimer] = []
    private(set) var sounds = 0
    private(set) var announcements = 0
    private(set) var loginReconciles = 0
    var reduceMotion = false
    var screencaptureUIRunning = false
    let model: AppModel

    init(onboardingShown: Bool = true) throws {
        let fm = FileManager.default
        home = try Fixtures.makeDir()
        folder = home.appendingPathComponent("Shots", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        prefs = FakeScreencapturePreferences(["location": folder.path])
        preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.onboardingShown = onboardingShown
        ledger = try RT.ledger()
        trasher = try FakeTrasher()
        logFile = try Fixtures.makeDir().appendingPathComponent("clipshot.log")
        let box = Box()
        let deps = AppDependencies(
            preferences: preferences, screencapturePrefs: prefs,
            backup: PrefsBackup(fileURL: home.appendingPathComponent("prefs-backup.plist")),
            home: home, events: events, pasteboard: pasteboard, ledger: ledger, trasher: trasher,
            hasTrash: RT.hasTrash, clock: { Date() }, pollInterval: .milliseconds(100),
            statusInterval: .milliseconds(100),
            hourly: hourly.eraseToAnyPublisher(), wake: wake.eraseToAnyPublisher(),
            makeFlashTimer: { interval, tolerance, tick in
                let timer = ManualFlashTimer(interval: interval, tolerance: tolerance, tick: tick)
                box.harness?.timers.append(timer)
                return timer
            },
            reduceMotion: { box.harness?.reduceMotion ?? false },
            playSound: { box.harness?.sounds += 1 },
            announce: { _ in box.harness?.announcements += 1 },
            workspace: workspace,
            screencaptureUIRunning: { box.harness?.screencaptureUIRunning ?? false },
            reconcileLoginItem: { intent in
                box.harness?.loginReconciles += 1
                return intent ?? false
            },
            setLoginItem: { _ in true },
            log: Log(fileURL: logFile), logFile: logFile,
            appVersion: "1.0.0 (1)", osVersion: "Version 26.0 (Build 25A1)")
        model = AppModel(dependencies: deps)
        box.harness = self
    }

    private final class Box {
        weak var harness: ModelHarness?
    }

    func tearDown() {
        model.stopWatching()
    }

    /// Starts and waits until the folder is watched.
    func start() async -> Bool {
        model.startWatching()
        return await eventually { await self.model.watchedFolder?.path == self.folder.path }
    }

    @discardableResult
    func shoot(_ name: String, size: Int = 16) throws -> URL {
        try Fixtures.write(named: name, contents: Fixtures.pngImage(size: size), in: folder)
    }

    var timer: ManualFlashTimer? { timers.last }
}

@MainActor
struct AppModelTests {
    @Test func doesNotWatchBeforeOnboardingStep2() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        h.model.launch()
        h.hourly.send()
        h.wake.send()
        h.model.refreshPreview()
        try? await Task.sleep(for: .milliseconds(500))
        #expect(h.events.starts == 0)
        #expect(h.prefs.synchronizeCount == 0, "com.apple.screencapture not read")
        #expect(h.loginReconciles == 0)
        #expect(h.timers.isEmpty)
        #expect(h.model.watchedFolder == nil)
        #expect(h.model.retentionPreview == nil)
        #expect(h.model.attentions.isEmpty)
        #expect(h.model.iconState == .idle)
        // Onboarding step 2.
        #expect(await h.start())
        #expect(h.events.starts == 1)
        #expect(h.loginReconciles == 1)
    }

    @Test func displayPathWritesTheModelsHomeAsTilde() throws {
        let h = try ModelHarness()
        #expect(h.model.displayPath(h.folder) == "~/Shots")
        #expect(h.model.displayPath(h.home) == "~")
        #expect(h.model.displayPath(URL(fileURLWithPath: "/Volumes/Shots")) == "/Volumes/Shots")
        // A sibling whose name starts with the home's is not inside it.
        let sibling = URL(fileURLWithPath: h.home.path + "-other/Shots")
        #expect(h.model.displayPath(sibling) == sibling.path)
    }

    @Test func launchStartsWatchingOnlyAfterOnboarding() async throws {
        let h = try ModelHarness(onboardingShown: true)
        defer { h.tearDown() }
        h.model.launch()
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
    }

    @Test func firstCopyHintShownUntilFirstCopy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(h.model.showFirstCopyHint)
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        #expect(await eventually { await !h.model.showFirstCopyHint })
        #expect(h.preferences.firstCopyDone)
        #expect(h.preferences.totals.copied == 1)
        #expect(h.model.lastCopied?.url.lastPathComponent == "Screenshot 1.png")
        #expect(h.announcements >= 1)
        #expect(h.sounds == 0, "copy sound is off by default")
    }

    @Test func copySoundPlaysOnlyWhenOn() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.copySound = true
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.sounds == 1 })
    }

    @Test func markupTipAfterThirdCopyOnce() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        for n in 1...2 {
            try h.shoot("Screenshot \(n).png", size: 16 + n)
            #expect(await eventually { await h.preferences.totals.copied == n })
            #expect(!h.model.showMarkupTip)
        }
        try h.shoot("Screenshot 3.png", size: 19)
        #expect(await eventually { await h.preferences.totals.copied == 3 })
        #expect(h.model.showMarkupTip)
        h.model.dismissMarkupTip()
        #expect(!h.model.showMarkupTip)
        #expect(h.preferences.markupTipShown)
        try h.shoot("Screenshot 4.png", size: 20)
        #expect(await eventually { await h.preferences.totals.copied == 4 })
        #expect(!h.model.showMarkupTip)
    }

    @Test func folderChangeRaisesRetentionAttention() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.retention = RT.policy(h.folder)
        #expect(await h.start())
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.model.attentions.isEmpty)
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.prefs["location"] = other.path
        #expect(await eventually {
            await h.model.attentions.map(\.id) == [Attention.retentionFolderChanged(other).id]
        })
        #expect(h.model.iconState == .attention)
        #expect(h.announcements >= 1, "a new attention is announced")
    }

    @Test func confirmRetentionFolderClearsAttention() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.retention = RT.policy(h.folder)
        #expect(await h.start())
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.prefs["location"] = other.path
        #expect(await eventually { await !h.model.attentions.isEmpty })
        // The preview is what the user confirms: it scans the new folder as if confirmed.
        h.model.refreshPreview()
        #expect(await eventually {
            await h.model.retentionPreview?.success?.folder.path == CaptureSettings.realPath(other)
        })
        #expect(await h.model.confirmRetentionFolder())
        #expect(h.preferences.retention.confirmed == ConfirmedFolder.of(other))
        #expect(await eventually { await h.model.attentions.isEmpty })
    }

    @Test func confirmRetentionFolderNeedsAPreview() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        #expect(await !h.model.confirmRetentionFolder())
        #expect(h.preferences.retention.confirmed == nil)
    }

    @Test func attentionClearsWhenFolderBecomesReadable() async throws {
        let h = try ModelHarness()
        defer {
            chmod(h.folder.path, 0o755)
            h.tearDown()
        }
        #expect(chmod(h.folder.path, 0o000) == 0)
        h.model.startWatching()
        #expect(await eventually {
            await h.model.attentions.map(\.id) == [Attention.folderAccessDenied(h.folder).id]
        })
        #expect(chmod(h.folder.path, 0o755) == 0)
        #expect(await eventually { await h.model.attentions.isEmpty })
        #expect(h.model.iconState == .idle)
    }

    @Test func couldNotCopyRaisesAttentionWithReportURL() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.pasteboard.failing = true
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.attentions.map(\.id) == [Attention.couldNotCopy.id] })
        #expect(h.model.iconState == .attention)
        // Lines that must never reach a public issue.
        try "2026-10-19T10:00:00Z INFO copied ext=png\n2026-10-19T10:00:01Z ERROR saw /Users/somebody/Pictures/x.png\n"
            .write(to: h.logFile, atomically: true, encoding: .utf8)
        let url = await h.model.reportIssueURL()
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == "github.com")
        #expect(parts.path == "/m-moravcik/ClipShot/issues/new")
        let title = try #require(parts.queryItems?.first { $0.name == "title" }?.value)
        let body = try #require(parts.queryItems?.first { $0.name == "body" }?.value)
        #expect(title.contains("could not copy"))
        #expect(body.contains("Version 26.0 (Build 25A1)"))
        #expect(body.contains("1.0.0 (1)"))
        #expect(body.contains("copied ext=png"))
        #expect(!body.contains("/Users/"))
        #expect(!body.contains("somebody"))
        #expect(!url.absoluteString.contains("somebody"))

        // Copy again recovers and clears the attention.
        h.pasteboard.failing = false
        #expect(await h.model.copyAgain())
        #expect(h.pasteboard.writes.count == 1)
        #expect(h.model.attentions.isEmpty)
    }

    @Test func reportIncludesOnlyTheLastTwentyLogLines() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let lines = (1...30).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: h.logFile, atomically: true, encoding: .utf8)
        let parts = try #require(URLComponents(url: await h.model.reportIssueURL(), resolvingAgainstBaseURL: false))
        let body = try #require(parts.queryItems?.first { $0.name == "body" }?.value)
        #expect(!body.contains("line 10\n"))
        #expect(body.contains("line 11\n"))
        #expect(body.contains("line 30\n"))
    }

    @Test func secondCopyDuringFlashRestartsSingleTimer() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png", size: 17)
        #expect(await eventually { await h.model.flashPhase == 1 })
        #expect(h.timers.count == 1)
        let timer = try #require(h.timer)
        #expect(timer.interval == 0.1)
        #expect(timer.tolerance == 0.025)
        #expect(h.model.iconState == .copied)
        timer.fire(5)
        #expect(h.model.flashPhase == 6)

        try h.shoot("Screenshot 2.png", size: 18)
        #expect(await eventually { await h.preferences.totals.copied == 2 })
        #expect(h.model.flashPhase == 1, "the second copy restarts the flash")
        #expect(h.timers.count == 1, "on the same timer")
        #expect(!timer.invalidated)

        timer.fire(CopiedFlash.steps - 1)
        #expect(h.model.flashPhase == 0)
        #expect(timer.invalidated)
        #expect(h.model.iconState == .idle)

        // A later copy starts a new timer and reads Reduce Motion again.
        h.reduceMotion = true
        try h.shoot("Screenshot 3.png", size: 19)
        #expect(await eventually { await h.timers.count == 2 })
        #expect(h.model.flashReduceMotion)
    }

    @Test func releasedModelStopsPollingAndItsFlashTimer() async throws {
        let ref = WeakModel()
        let prefs: FakeScreencapturePreferences
        let timer: ManualFlashTimer
        do {
            let h = try ModelHarness()
            #expect(await h.start())
            try h.shoot("Screenshot 1.png")
            #expect(await eventually { await h.timers.count == 1 })
            timer = h.timers[0]
            prefs = h.prefs
            ref.value = h.model
        }
        for _ in 0..<50 where ref.value != nil { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(ref.value == nil, "nothing keeps a released model alive")
        #expect(timer.invalidated)
        let reads = prefs.synchronizeCount
        try? await Task.sleep(for: .milliseconds(500))
        #expect(prefs.synchronizeCount == reads, "no poll reads the prefs after release")
    }

    @Test func releasedSystemFlashTimerStopsTicking() async {
        let ticks = TickCounter()
        do {
            let timer = SystemFlashTimer(interval: 0.02, tolerance: 0.005) { ticks.count += 1 }
            #expect(await eventually { await ticks.count >= 2 })
            withExtendedLifetime(timer) {}
        }
        let after = ticks.count
        try? await Task.sleep(for: .milliseconds(200))
        #expect(ticks.count == after)
    }

    @Test func cleanUpNowUpdatesTotals() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = Date()
        var bytes: Int64 = 0
        for name in ["old 1.png", "old 2.png"] {
            let url = try RT.shot(name, in: h.folder, age: 40 * RT.day, now: now)
            bytes += RT.file(url).size
            await h.ledger.record(RT.file(url))
        }
        #expect(await h.start())
        // Off at launch: the start run does nothing.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.trasher.trashed.isEmpty)
        h.preferences.retention = RT.policy(h.folder)
        await h.model.cleanUpNow()
        #expect(Set(h.trasher.trashed) == ["old 1.png", "old 2.png"])
        #expect(h.preferences.totals.trashed == 2)
        #expect(h.preferences.totals.freedBytes == bytes)
        #expect(h.preferences.lastRetention?.moved == 2)
        #expect(h.preferences.lastRetention?.movedBytes == bytes)
    }

    @Test func retentionRunsOnWake() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let url = try RT.shot("old.png", in: h.folder, age: 40 * RT.day, now: Date())
        await h.ledger.record(RT.file(url))
        #expect(await h.start())
        try? await Task.sleep(for: .milliseconds(300))
        h.preferences.retention = RT.policy(h.folder)
        h.wake.send()
        #expect(await eventually { await h.preferences.totals.trashed == 1 })
    }

    @Test func copyToggleMirrorsIntoCoordinator() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.preferences.copyEnabled = false
        #expect(await eventually { await h.model.iconState == .paused })
        try h.shoot("While off.png")
        try? await Task.sleep(for: .milliseconds(1_500))
        #expect(h.pasteboard.writes.isEmpty)
    }

    @Test func revealAndOpenUseTheWorkspace() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.lastCopied != nil })
        h.model.revealLast()
        #expect(h.workspace.revealed.map(\.lastPathComponent) == [url.lastPathComponent])
        h.model.openFolder()
        #expect(h.workspace.opened.map(\.path) == [h.folder.path])
    }

    @Test func destinationNotFileRaisesAttentionAndFixClearsIt() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["target"] = "clipboard"
        #expect(await h.start())
        #expect(await eventually { await h.model.attentions.map(\.id) == [Attention.destinationNotFile.id] })
        await h.model.fixDestination()
        #expect(h.prefs["target"] as? String == "file")
        #expect(await eventually { await h.model.attentions.isEmpty })
    }
}
