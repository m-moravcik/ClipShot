import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// Records what would have gone to the pasteboard. Never touches the real general pasteboard.
@MainActor
final class RecordingPasteboard: PasteboardWriting {
    private(set) var writes: [Data] = []
    var failing = false
    /// Another app's copy bumps it too.
    var changeCount = 0

    func writePNG(_ data: Data) -> Bool {
        guard !failing else { return false }
        writes.append(data)
        changeCount += 1
        return true
    }
}

/// A coordinator on a real temp folder with a real `DirectoryEventSource`.
@MainActor
final class CoordinatorHarness {
    let home: URL
    let folder: URL
    let desktop: URL
    let prefs: FakeScreencapturePreferences
    let settings: CaptureSettings
    let pasteboard = RecordingPasteboard()
    let ledger: ScreenshotLedger
    let edits = EditSession()
    let coordinator: CopyCoordinator
    let logFile: URL
    private(set) var failures = 0

    /// `sleepUntil`: how rescans wait; a test can release them by hand.
    init(
        createFolder: Bool = true, createDesktop: Bool = false,
        sleepUntil: (@Sendable (ContinuousClock.Instant) async throws -> Void)? = nil,
        readMarker: @escaping @Sendable (URL) -> Bool = { CaptureMarker.isScreenshot($0) },
        trust: FileTrust.Policy = .standard, events: (any FolderEventSource)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let fm = FileManager.default
        home = try Fixtures.makeDir()
        folder = home.appendingPathComponent("Shots", isDirectory: true)
        desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        if createFolder { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        if createDesktop { try fm.createDirectory(at: desktop, withIntermediateDirectories: true) }
        prefs = FakeScreencapturePreferences(["location": folder.path])
        settings = CaptureSettings(
            prefs: prefs, home: home, backup: PrefsBackup(fileURL: home.appendingPathComponent("backup.plist")),
            log: try RT.testLog())
        ledger = try RT.ledger()
        logFile = home.appendingPathComponent("clipshot.log")
        coordinator = CopyCoordinator(
            settings: settings, events: events ?? DirectoryEventSource(), pasteboard: pasteboard, ledger: ledger,
            edits: edits, clock: clock, pollInterval: .milliseconds(100), home: home, log: Log(fileURL: logFile),
            sleepUntil: sleepUntil ?? { try await Task.sleep(until: $0, clock: .continuous) },
            readMarker: readMarker, trust: trust)
        coordinator.onFailure = { [weak self] _ in self?.failures += 1 }
    }

    /// Starts and waits until the folder is watched and seeded.
    func start(watching expected: URL? = nil) async -> Bool {
        coordinator.start()
        let path = (expected ?? folder).path
        return await eventually { await self.coordinator.watchedFolder?.path == path }
    }

    /// Waits until every pass and rescan the events so far asked for has run (the last
    /// rescan is 3 s after an event): what a "nothing else happened" check waits for, rather
    /// than a fixed sleep that may end before the pass it is about (R-9).
    func settled() async -> Bool {
        await eventually(timeout: .seconds(10)) { await self.coordinator.isIdle }
    }

    /// `settled()`, once a folder event after `events` was handled.
    func settled(after events: Int) async -> Bool {
        await eventually(timeout: .seconds(10)) { await self.isSettled(after: events) }
    }

    private func isSettled(after events: Int) -> Bool {
        coordinator.eventsHandled > events && coordinator.isIdle
    }

    var writes: [Data] { pasteboard.writes }

    var logText: String { (try? String(contentsOf: logFile, encoding: .utf8)) ?? "" }

    /// Whether the log reports whole seconds in `expected` right after `prefix`. A range, not a
    /// value: the real time the passes take adds to the clock's offset, so a loaded machine may
    /// log a second or two more.
    func logged(_ prefix: String, seconds expected: Range<Int>) -> Bool {
        let text = logText
        guard let range = text.range(of: prefix),
              let seconds = Int(text[range.upperBound...].prefix(while: \.isNumber))
        else { return false }
        return expected.contains(seconds)
    }

    func ledgerNames() async -> [String] {
        await ledger.entries().map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    static func png(_ size: Int) -> Data { Fixtures.pngImage(size: size) }
}

@MainActor
struct CopyCoordinatorTests {

    @Test func copiesNewScreenshot() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let data = CoordinatorHarness.png(20)
        try Fixtures.write(named: "Screenshot 1.png", contents: data, in: h.folder)
        #expect(await eventually { await h.writes == [data] })
        #expect(h.coordinator.lastCopied?.url.lastPathComponent == "Screenshot 1.png")
        #expect(await eventually { await h.ledgerNames() == ["Screenshot 1.png"] })
        #expect(h.coordinator.watchError == nil)
    }

    @Test func ignoresUnmarkedNewFile() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        try Fixtures.write(named: "photo.png", contents: CoordinatorHarness.png(21), in: h.folder,
                           marker: .none, captureType: false)
        try Fixtures.write(named: "downloaded.png", contents: CoordinatorHarness.png(22), in: h.folder,
                           quarantine: true)
        let shot = CoordinatorHarness.png(23)
        try Fixtures.write(named: "Screenshot.png", contents: shot, in: h.folder)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(await h.settled())
        #expect(h.writes == [shot])
        #expect(await h.ledgerNames() == ["Screenshot.png"])
    }

    @Test func launchDoesNotCopyExistingFiles() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        try Fixtures.write(named: "Existing.png", contents: CoordinatorHarness.png(24), in: h.folder)
        #expect(await h.start())
        let fresh = CoordinatorHarness.png(25)
        try Fixtures.write(named: "New.png", contents: fresh, in: h.folder)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(await h.settled())
        #expect(h.writes == [fresh])
        #expect(await h.ledgerNames() == ["New.png"])
    }

    @Test func doesNotCatchUpAfterReenable() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        h.coordinator.isEnabled = false
        #expect(await h.start())
        try Fixtures.write(named: "While off.png", contents: CoordinatorHarness.png(26), in: h.folder)
        #expect(await eventually { await h.ledgerNames() == ["While off.png"] })
        h.coordinator.isEnabled = true
        let after = CoordinatorHarness.png(27)
        try Fixtures.write(named: "After.png", contents: after, in: h.folder)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(await h.settled())
        #expect(h.writes == [after])
    }

    @Test func burstCopiesEachOnceNewestLast() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let shots = [28, 29, 30].map(CoordinatorHarness.png)
        for (i, data) in shots.enumerated() {
            if i > 0 { try await Task.sleep(for: .milliseconds(300)) }
            try Fixtures.write(named: "Burst \(i).png", contents: data, in: h.folder)
        }
        #expect(await eventually { await h.writes.count == 3 })
        #expect(await h.settled())
        #expect(h.writes == shots)
        #expect(h.coordinator.lastCopied?.url.lastPathComponent == "Burst 2.png")
    }

    @Test func copiesAgainWhenMarkupRewritesFile() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let original = CoordinatorHarness.png(31)
        let url = try Fixtures.write(named: "Screenshot.png", contents: original, in: h.folder)
        #expect(await eventually { await h.writes == [original] })
        // Markup Done (spike F7): a new dot-temp file renamed over the same name, marked after.
        let edited = CoordinatorHarness.png(32)
        let temp = h.folder.appendingPathComponent(".Screenshot.png")
        try edited.write(to: temp)
        #expect(rename(temp.path, url.path) == 0)
        Fixtures.mark(url)
        #expect(await eventually { await h.writes.count == 2 })
        #expect(await h.settled())
        #expect(h.writes == [original, edited])
    }

    @Test func multiDisplayCaptureCopiesMainDisplayOnly() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let main = CoordinatorHarness.png(33)
        try Fixtures.write(named: "Screenshot 1.png", contents: main, in: h.folder, kind: "display")
        try await Task.sleep(for: .milliseconds(50))
        try Fixtures.write(named: "Screenshot 1 (2).png", contents: CoordinatorHarness.png(34),
                           in: h.folder, kind: "display")
        #expect(await eventually {
            let recorded = await h.ledgerNames().count
            let written = await h.writes.count
            return recorded == 2 && written >= 1
        })
        #expect(await h.settled())
        #expect(h.writes == [main])
        #expect(await h.ledgerNames() == ["Screenshot 1 (2).png", "Screenshot 1.png"])
    }

    @Test func missingFolderWatchesDesktopFallback() async throws {
        let h = try CoordinatorHarness(createFolder: false, createDesktop: true)
        defer { h.coordinator.stop() }
        #expect(await h.start(watching: h.desktop))
        #expect(h.coordinator.watchError == .folderMissing(h.settings.folder()))
        let data = CoordinatorHarness.png(35)
        try Fixtures.write(named: "Screenshot.png", contents: data, in: h.desktop)
        #expect(await eventually { await h.writes == [data] })
    }

    @Test func copiesWhenMarkerArrivesAfterCreate() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let data = CoordinatorHarness.png(36)
        let url = try Fixtures.write(named: "Screenshot.png", contents: data, in: h.folder,
                                     marker: .none, captureType: false)
        try await Task.sleep(for: .milliseconds(600))
        Fixtures.mark(url)
        #expect(await eventually { await h.writes == [data] })
    }

    @Test func retargetsWhenFolderPrefChanges() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.prefs["location"] = other.path
        #expect(await eventually { await h.coordinator.watchedFolder?.path == other.path })
        try Fixtures.write(named: "Old place.png", contents: CoordinatorHarness.png(37), in: h.folder)
        let data = CoordinatorHarness.png(38)
        try Fixtures.write(named: "New place.png", contents: data, in: other)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(await h.settled())
        #expect(h.writes == [data])
    }

    @Test func missingFolderSetsWatchError() async throws {
        let h = try CoordinatorHarness(createFolder: false)
        defer { h.coordinator.stop() }
        h.coordinator.start()
        #expect(await eventually { await h.coordinator.watchError == .folderMissing(h.settings.folder()) })
        #expect(h.coordinator.watchedFolder == nil)
    }

    @Test func detectsFolderDeletedWhileWatching() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        #expect(h.coordinator.watchError == nil)
        // Moved away, as moving it to the Trash does.
        #expect(rename(h.folder.path, h.home.appendingPathComponent("Gone").path) == 0)
        #expect(await eventually { await h.coordinator.watchError == .folderRemoved(h.settings.folder()) })
    }

    @Test func recoversWhenFolderReappears() async throws {
        let h = try CoordinatorHarness(createFolder: false)
        defer { h.coordinator.stop() }
        h.coordinator.start()
        #expect(await eventually { await h.coordinator.watchError == .folderMissing(h.settings.folder()) })
        try FileManager.default.createDirectory(at: h.folder, withIntermediateDirectories: true)
        #expect(await eventually {
            let error = await h.coordinator.watchError
            let watched = await h.coordinator.watchedFolder
            return error == nil && watched?.path == h.folder.path
        })
        let data = CoordinatorHarness.png(39)
        try Fixtures.write(named: "Screenshot.png", contents: data, in: h.folder)
        #expect(await eventually { await h.writes == [data] })
    }

    @Test func unreadableFolderSetsAccessDenied() async throws {
        let h = try CoordinatorHarness()
        defer {
            h.coordinator.stop()
            chmod(h.folder.path, 0o755)
        }
        #expect(chmod(h.folder.path, 0) == 0)
        h.coordinator.start()
        #expect(await eventually { await h.coordinator.watchError == .accessDenied(h.settings.folder()) })
        #expect(h.coordinator.watchedFolder == nil)
    }

    @Test func observedScreenshotIsRecordedInLedgerEvenWhenCopyDisabled() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        try Fixtures.write(named: "Before launch.png", contents: CoordinatorHarness.png(40), in: h.folder)
        h.coordinator.isEnabled = false
        #expect(await h.start())
        try Fixtures.write(named: "Screenshot.png", contents: CoordinatorHarness.png(41), in: h.folder)
        #expect(await eventually { await h.ledgerNames() == ["Screenshot.png"] })
        #expect(await h.settled())
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames() == ["Screenshot.png"])
    }

    @Test func conversionFailureReportsFailure() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let full = CoordinatorHarness.png(64)
        try Fixtures.write(named: "Screenshot.png", contents: full.prefix(full.count / 2), in: h.folder)
        #expect(await eventually { await h.failures == 1 })
        #expect(h.coordinator.lastFailure != nil)
        #expect(h.writes.isEmpty)
        #expect(await h.settled())
        #expect(h.failures == 1)
    }

    @Test func pasteboardFailureReportsFailure() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        h.pasteboard.failing = true
        #expect(await h.start())
        try Fixtures.write(named: "Screenshot.png", contents: CoordinatorHarness.png(42), in: h.folder)
        #expect(await eventually { await h.failures == 1 })
        #expect(h.coordinator.lastFailure != nil)
        #expect(h.coordinator.lastCopied == nil)
        #expect(await h.settled())
        #expect(h.failures == 1)
    }

    // MARK: - Fix round 1

    @Test func retriesScreenshotThatDecodesOnRescan() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let full = CoordinatorHarness.png(43)
        let url = try Fixtures.write(named: "Screenshot.png", contents: full.prefix(full.count / 2), in: h.folder)
        // The event's pass sees the truncated bytes; the rest arrives before the 250 ms rescan.
        try await Task.sleep(for: .milliseconds(120))
        try full.write(to: url)
        #expect(await eventually { await h.writes == [full] })
        #expect(await h.settled())
        #expect(h.writes == [full])
        #expect(h.failures == 0)
        #expect(h.coordinator.lastFailure == nil)
    }

    @Test func multiDisplayWaitsForMainDisplayMarker() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        // F3 + F4: the main display file is in place but unmarked when the secondary one is marked.
        let main = CoordinatorHarness.png(44)
        let mainURL = try Fixtures.write(named: "Screenshot 2.png", contents: main, in: h.folder,
                                         marker: .none, captureType: false)
        try await Task.sleep(for: .milliseconds(10))
        try Fixtures.write(named: "Screenshot 2 (2).png", contents: CoordinatorHarness.png(45),
                           in: h.folder, kind: "display")
        try await Task.sleep(for: .milliseconds(60))
        Fixtures.mark(mainURL, kind: "display")
        #expect(await eventually { await h.writes.count >= 1 })
        #expect(await h.settled())
        #expect(h.writes == [main])
        #expect(await h.ledgerNames() == ["Screenshot 2 (2).png", "Screenshot 2.png"])
    }

    @Test func stateChangeFiresOnFolderMissingAndOnCopy() async throws {
        let h = try CoordinatorHarness(createFolder: false, createDesktop: true)
        defer { h.coordinator.stop() }
        var states: [(error: WatchError?, copied: String?)] = []
        h.coordinator.onStateChange = { [coordinator = h.coordinator] in
            states.append((coordinator.watchError, coordinator.lastCopied?.url.lastPathComponent))
        }
        #expect(await h.start(watching: h.desktop))
        let missing = WatchError.folderMissing(h.settings.folder())
        #expect(states.contains { $0.error == missing })
        let before = states.count
        try Fixtures.write(named: "Screenshot.png", contents: CoordinatorHarness.png(46), in: h.desktop)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(states.count > before)
        #expect(states.last?.copied == "Screenshot.png")
    }

    /// After `stop()` the folder is no longer watched at all: the watch itself is stopped
    /// (not only ignored), and a screenshot that a control watcher on the same folder does
    /// see reaches the stopped coordinator not even as an event.
    @Test func nothingIsCopiedAfterStop() async throws {
        let source = RecordingEventSource()
        let h = try CoordinatorHarness(events: source)
        #expect(await h.start())
        #expect(source.isWatching)
        h.coordinator.stop()
        #expect(await eventually { !source.isWatching }, "stop() stops the watch")

        let control = RecordingEventSource()
        try control.start(h.folder) {}
        defer { control.stop() }
        try Fixtures.write(named: "Screenshot.png", contents: CoordinatorHarness.png(47), in: h.folder)
        #expect(await eventually { control.delivered > 0 }, "the write fired an event")
        #expect(source.delivered == 0, "the stopped coordinator's watch saw nothing")
        #expect(h.coordinator.eventsHandled == 0)
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames().isEmpty)
        #expect(h.coordinator.watchedFolder == nil)
    }

    @Test func retargetDoesNotCopyFreshScreenshotAlreadyThere() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Fixtures.write(named: "Already there.png", contents: CoordinatorHarness.png(48), in: other)
        h.prefs["location"] = other.path
        #expect(await eventually { await h.coordinator.watchedFolder?.path == other.path })
        let data = CoordinatorHarness.png(49)
        try Fixtures.write(named: "New.png", contents: data, in: other)
        #expect(await eventually { await h.writes.count == 1 })
        #expect(await h.settled())
        #expect(h.writes == [data])
        #expect(await h.ledgerNames() == ["New.png"])
    }

    /// 2026-10-27: Spotlight held `screencapture` up for 69 s between writing the hidden file
    /// and renaming it into place. Birth and modification time are then 69 s old when the file
    /// appears; it is still copied once, recorded and shown.
    @Test func copiesCaptureRenamedIntoPlaceLate() async throws {
        let clock = OffsetClock()
        let h = try CoordinatorHarness(clock: clock.now)
        defer { h.coordinator.stop() }
        #expect(await h.start())
        #expect(await h.settled())
        let passes = h.coordinator.passesFinished
        let data = CoordinatorHarness.png(50)
        let temp = h.folder.appendingPathComponent(".Screenshot late.png")
        try data.write(to: temp)
        #expect(await eventually { await h.coordinator.passesFinished > passes })
        clock.advance(by: 69)
        let url = h.folder.appendingPathComponent("Screenshot late.png")
        #expect(rename(temp.path, url.path) == 0)
        Fixtures.mark(url)
        #expect(await eventually { await h.writes == [data] })
        #expect(await h.settled())
        #expect(h.writes == [data])
        #expect(await h.ledgerNames() == ["Screenshot late.png"])
        #expect(await eventually { await h.logged("copied late ext=png, macOS held it back ", seconds: 69..<75) })
    }

    /// A hidden file already there when watching starts is never copied, even when other folder
    /// activity makes a pass list it while it is still fresh.
    @Test func doesNotCopyCaptureHiddenWhenWatchingStarts() async throws {
        let clock = OffsetClock()
        let h = try CoordinatorHarness(clock: clock.now)
        defer { h.coordinator.stop() }
        let temp = h.folder.appendingPathComponent(".Screenshot early.png")
        try CoordinatorHarness.png(52).write(to: temp)
        #expect(await h.start())
        let passes = h.coordinator.passesFinished
        try Fixtures.write(named: "notes.txt", contents: Data("x".utf8), in: h.folder)
        #expect(await eventually { await h.coordinator.passesFinished > passes })
        clock.advance(by: 40)
        let url = h.folder.appendingPathComponent("Screenshot early.png")
        #expect(rename(temp.path, url.path) == 0)
        Fixtures.mark(url)
        #expect(await eventually { await h.logged("not copied, created ", seconds: 40..<46) })
        #expect(await h.settled())
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames().isEmpty)
    }

    /// A capture taken while copying is off is never copied, even when macOS renames it into place
    /// after copying is back on and a pass saw the hidden file while it was still fresh.
    @Test func doesNotCopyCaptureHiddenWhileCopyingIsOff() async throws {
        let clock = OffsetClock()
        let h = try CoordinatorHarness(clock: clock.now)
        defer { h.coordinator.stop() }
        #expect(await h.start())
        h.coordinator.isEnabled = false
        let paused = h.coordinator.passesFinished
        let temp = h.folder.appendingPathComponent(".Screenshot paused.png")
        try CoordinatorHarness.png(54).write(to: temp)
        #expect(await eventually { await h.coordinator.passesFinished > paused })
        h.coordinator.isEnabled = true
        let resumed = h.coordinator.passesFinished
        try Fixtures.write(named: "notes.txt", contents: Data("x".utf8), in: h.folder)
        #expect(await eventually { await h.coordinator.passesFinished > resumed })
        clock.advance(by: 40)
        let url = h.folder.appendingPathComponent("Screenshot paused.png")
        #expect(rename(temp.path, url.path) == 0)
        Fixtures.mark(url)
        #expect(await eventually { await h.logged("not copied, created ", seconds: 40..<46) })
        #expect(await h.settled())
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames().isEmpty)
    }

    /// The same late birth time without a hidden file ClipShot saw: an old screenshot put back
    /// from the Trash or moved in. Not copied, and the log says why.
    @Test func doesNotCopyOldScreenshotThatWasNeverHidden() async throws {
        let clock = OffsetClock()
        let h = try CoordinatorHarness(clock: clock.now)
        defer { h.coordinator.stop() }
        #expect(await h.start())
        clock.advance(by: 69)
        try Fixtures.write(named: "Put back.png", contents: CoordinatorHarness.png(51), in: h.folder)
        #expect(await eventually { await h.logged("not copied, created ", seconds: 69..<75) })
        #expect(await h.settled())
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames().isEmpty)
    }

    /// The marker lands after the rename and fires no event (spike F5). An old screenshot whose
    /// marker is set only after the first pass listed it is still logged, once, and not copied.
    @Test func logsOldScreenshotMarkedAfterTheFirstPass() async throws {
        let clock = OffsetClock()
        let h = try CoordinatorHarness(clock: clock.now)
        defer { h.coordinator.stop() }
        #expect(await h.start())
        #expect(await h.settled())
        clock.advance(by: 69)
        let passes = h.coordinator.passesFinished
        let url = try Fixtures.write(
            named: "Marked late.png", contents: CoordinatorHarness.png(53), in: h.folder,
            marker: .none, captureType: false)
        #expect(await eventually { await h.coordinator.passesFinished > passes })
        Fixtures.mark(url)
        #expect(await eventually { await h.logged("not copied, created ", seconds: 69..<75) })
        #expect(await h.settled())
        #expect(h.writes.isEmpty)
        #expect(await h.ledgerNames().isEmpty)
        #expect(h.logText.components(separatedBy: "not copied, created ").count == 2)
    }
}

/// Wall time moved forward by hand, for a capture macOS holds back longer than a test should wait.
final class OffsetClock: Sendable {
    private let offset = Mutex<TimeInterval>(0)

    func advance(by seconds: TimeInterval) { offset.withLock { $0 += seconds } }

    @Sendable func now() -> Date { Date().addingTimeInterval(offset.withLock { $0 }) }
}

/// A real kqueue watch that says whether it is running and counts the events it delivers.
final class RecordingEventSource: FolderEventSource, Sendable {
    private let inner = DirectoryEventSource()
    private let state = Mutex((watching: false, delivered: 0))

    var isWatching: Bool { state.withLock { $0.watching } }
    var delivered: Int { state.withLock { $0.delivered } }

    func start(_ folder: URL, onEvent: @escaping @Sendable () -> Void) throws(WatchError) {
        try inner.start(folder) { [weak self] in
            self?.state.withLock { $0.delivered += 1 }
            onEvent()
        }
        state.withLock { $0.watching = true }
    }

    func stop() {
        inner.stop()
        state.withLock { $0.watching = false }
    }
}
