import Foundation
import Testing
@testable import ClipShot

/// Records what would have gone to the pasteboard. Never touches the real general pasteboard.
@MainActor
final class RecordingPasteboard: PasteboardWriting {
    private(set) var writes: [Data] = []
    var failing = false

    func writePNG(_ data: Data) -> Bool {
        guard !failing else { return false }
        writes.append(data)
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
    let coordinator: CopyCoordinator
    private(set) var failures = 0

    init(createFolder: Bool = true, createDesktop: Bool = false) throws {
        let fm = FileManager.default
        home = try Fixtures.makeDir()
        folder = home.appendingPathComponent("Shots", isDirectory: true)
        desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        if createFolder { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        if createDesktop { try fm.createDirectory(at: desktop, withIntermediateDirectories: true) }
        prefs = FakeScreencapturePreferences(["location": folder.path])
        settings = CaptureSettings(
            prefs: prefs, home: home, backup: PrefsBackup(fileURL: home.appendingPathComponent("backup.plist")))
        ledger = try RT.ledger()
        coordinator = CopyCoordinator(
            settings: settings, events: DirectoryEventSource(), pasteboard: pasteboard, ledger: ledger,
            clock: { Date() }, pollInterval: .milliseconds(100), home: home, log: try RT.testLog())
        coordinator.onFailure = { [weak self] in self?.failures += 1 }
    }

    /// Starts and waits until the folder is watched and seeded.
    func start(watching expected: URL? = nil) async -> Bool {
        coordinator.start()
        let path = (expected ?? folder).path
        return await eventually { await self.coordinator.watchedFolder?.path == path }
    }

    var writes: [Data] { pasteboard.writes }

    func ledgerNames() async -> [String] {
        await ledger.entries().map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    static func png(_ size: Int) -> Data { Fixtures.pngImage(size: size) }
}

@MainActor
struct CopyCoordinatorTests {
    /// Longer than the last rescan, so a wrong late copy would have happened.
    private func settle() async { try? await Task.sleep(for: .milliseconds(3_400)) }

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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
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
        await settle()
        #expect(h.failures == 1)
    }
}
