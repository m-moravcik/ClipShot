import Foundation
import Testing
@testable import ClipShot

/// A real event source whose `stop()` blocks while the gate is closed. The coordinator runs
/// `stop()` on its serial IO queue, so a closed gate holds everything queued behind it.
final class GatedEventSource: FolderEventSource, @unchecked Sendable {
    private let inner = DirectoryEventSource()
    private let condition = NSCondition()
    private var closed = false

    func close() {
        condition.lock()
        closed = true
        condition.unlock()
    }

    func open() {
        condition.lock()
        closed = false
        condition.broadcast()
        condition.unlock()
    }

    func start(_ folder: URL, onEvent: @escaping @Sendable () -> Void) throws(WatchError) {
        try inner.start(folder, onEvent: onEvent)
    }

    func stop() {
        condition.lock()
        while closed { condition.wait() }
        condition.unlock()
        inner.stop()
    }
}

/// `stop()` while a prefs read is queued on the coordinator's IO queue: the read must not run
/// after the stop, and the run started next must read once and publish its state.
@MainActor
struct CopyCoordinatorStopTests {
    @Test func prefsReadQueuedBeforeAStopIsSkipped() async throws {
        let home = try Fixtures.makeDir()
        let folder = home.appendingPathComponent("Shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefs = FakeScreencapturePreferences(["location": folder.path])
        let events = GatedEventSource()
        let settings = CaptureSettings(
            prefs: prefs, home: home, backup: PrefsBackup(fileURL: home.appendingPathComponent("backup.plist")),
            log: try RT.testLog())
        // No poll during the test: every read comes from a start().
        let coordinator = CopyCoordinator(
            settings: settings, events: events, pasteboard: RecordingPasteboard(),
            ledger: try RT.ledger(), clock: { Date() }, pollInterval: .seconds(3_600), home: home,
            log: try RT.testLog())
        defer {
            events.open()
            coordinator.stop()
        }

        coordinator.start()
        #expect(await eventually { await coordinator.watchedFolder?.path == folder.path })
        #expect(prefs.synchronizeCount == 1)

        // The IO queue stalls in the event source's stop().
        events.close()
        coordinator.stop()
        // Run B: its prefs read is queued behind the stalled stop() ...
        coordinator.start()
        try await Task.sleep(for: .milliseconds(100))
        // ... and B is stopped before the queue reaches it.
        coordinator.stop()
        // Run C: the run that stays.
        coordinator.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(prefs.synchronizeCount == 1, "everything waits behind the stalled stop()")

        events.open()
        #expect(await eventually { await coordinator.watchedFolder?.path == folder.path })
        try await Task.sleep(for: .milliseconds(300))
        #expect(prefs.synchronizeCount == 2, "C read once; B's queued read was skipped")
        #expect(coordinator.watchError == nil)
    }
}
