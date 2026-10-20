import Foundation
import Testing
@testable import ClipShot

/// The model API the popover and Settings bind to.
@MainActor
struct AppModelUITests {
    /// An expired screenshot ClipShot never saw, in a folder retention is confirmed for.
    private func harnessWithOlderScreenshot() async throws -> (ModelHarness, URL) {
        let h = try ModelHarness()
        let old = try RT.shot("old.png", in: h.folder, age: 40 * RT.day, now: Date())
        h.preferences.retention = RT.policy(h.folder)
        #expect(await h.start())
        h.model.refreshPreview()
        #expect(await eventually { await h.model.retentionPreview?.success?.olderNotTracked == 1 })
        return (h, old)
    }

    @Test func adoptOlderScreenshotsAddsThemToTheLedgerAndRefreshesThePreview() async throws {
        let (h, old) = try await harnessWithOlderScreenshot()
        defer { h.tearDown() }
        let scan = try #require(h.model.retentionPreview?.success)
        #expect(scan.expired.isEmpty)
        #expect(scan.olderNotTrackedBytes == RT.file(old).size)

        #expect(await h.model.adoptOlderScreenshots() == 1)
        #expect(await h.ledger.contains(path: FolderGuard.canonicalPath(old), resourceID: RT.file(old).resourceID))
        #expect(await eventually {
            await h.model.retentionPreview?.success.map { $0.expired.count == 1 && $0.olderNotTracked == 0 } == true
        })
        #expect(h.trasher.trashed.isEmpty, "adopting moves nothing by itself")

        // The next run moves it.
        let result = await h.model.cleanUpNow()
        #expect(result?.moved == 1)
        #expect(h.trasher.trashed == ["old.png"])
    }

    /// The confirmed count is the count the user saw: a qualifying file that appears between
    /// the preview and the confirmation is not adopted, nor is a counted one replaced since.
    @Test func adoptOnlyTheFilesThePreviewCounted() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = Date()
        let kept = try RT.shot("old 1.png", in: h.folder, age: 40 * RT.day, now: now)
        let replaced = try RT.shot("old 2.png", in: h.folder, age: 45 * RT.day, now: now)
        h.preferences.retention = RT.policy(h.folder)
        #expect(await h.start())
        h.model.refreshPreview()
        #expect(await eventually { await h.model.retentionPreview?.success?.olderNotTracked == 2 })

        // After the preview: a new qualifying file, and a counted one replaced by another.
        let late = try RT.shot("late.png", in: h.folder, age: 50 * RT.day, now: now)
        let moved = Fixtures.stagingDir.appendingPathComponent("old 2-\(UUID()).png")
        try FileManager.default.moveItem(at: replaced, to: moved)
        try RT.shot("old 2.png", in: h.folder, age: 45 * RT.day, now: now)

        #expect(await h.model.adoptOlderScreenshots() == 1)
        let entries = await h.ledger.entries()
        #expect(entries.map { ($0.path as NSString).lastPathComponent } == ["old 1.png"])
        #expect(await h.ledger.contains(path: FolderGuard.canonicalPath(kept), resourceID: RT.file(kept).resourceID))
        #expect(await !h.ledger.contains(path: FolderGuard.canonicalPath(late), resourceID: RT.file(late).resourceID))
    }

    @Test func adoptOlderScreenshotsNeedsAPreview() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try RT.shot("old.png", in: h.folder, age: 40 * RT.day, now: Date())
        #expect(await h.start())
        #expect(await h.model.adoptOlderScreenshots() == 0)
        #expect(await h.ledger.entries().isEmpty)
    }

    @Test func adoptOlderScreenshotsRefusesAfterTheFolderChanged() async throws {
        let (h, _) = try await harnessWithOlderScreenshot()
        defer { h.tearDown() }
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.prefs["location"] = other.path
        #expect(await h.model.adoptOlderScreenshots() == 0)
        #expect(await h.ledger.entries().isEmpty)
    }

    @Test func latestCardCopiesTheShownScreenshotNotTheFailedOne() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let first = try h.shoot("Screenshot 1.png", size: 20)
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 1.png" })
        h.pasteboard.failing = true
        let second = try h.shoot("Screenshot 2.png", size: 21)
        #expect(await eventually { await h.model.attentions.map(\.id) == [Attention.couldNotCopy.id] })
        let shown = try #require(h.model.latest)
        #expect(shown.file.url.lastPathComponent == "Screenshot 1.png", "the card keeps the last good copy")

        // The card's Copy again: the screenshot it shows, and the failure stays reported.
        h.pasteboard.failing = false
        #expect(await h.model.copyAgain(file: shown.file))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: first)))
        #expect(h.model.attentions.map(\.id) == [Attention.couldNotCopy.id])

        // The attention row's Copy again: the failed one, which clears it.
        #expect(await h.model.copyAgain())
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: second)))
        #expect(h.model.attentions.isEmpty)
    }

    @Test func runThatMovesNothingKeepsTheLastCleanup() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let url = try RT.shot("old.png", in: h.folder, age: 40 * RT.day, now: Date())
        await h.ledger.record(RT.file(url))
        #expect(await h.start())
        #expect(await h.model.cleanUpNow() == nil, "off: the start run, and this one, do nothing")
        #expect(h.preferences.lastRetention == nil, "off at launch: nothing recorded")
        h.preferences.retention = RT.policy(h.folder)

        let moved = try #require(await h.model.cleanUpNow())
        #expect(moved.moved == 1)
        #expect(h.preferences.lastRetention == moved)

        let empty = try #require(await h.model.cleanUpNow(), "the run happened")
        #expect(empty.moved == 0)
        #expect(h.preferences.lastRetention == moved, "a no-op run does not replace the summary")
        #expect(h.preferences.totals.trashed == 1)
    }

    @Test func cleanUpNowReturnsNilWhenNothingRan() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.model.cleanUpNow() == nil, "not watching")
        #expect(await h.start())
        #expect(await h.model.cleanUpNow() == nil, "retention off")
    }

    @Test func pdfWithThumbnailOnIsFlagged() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["type"] = "pdf"
        #expect(await h.start())
        #expect(await eventually { await h.model.captureFormat == "pdf" })
        #expect(await eventually { await h.model.showThumbnail == true })
        #expect(h.model.pdfSavesNoFile)

        await h.model.setPreviewMode(.clipShot)
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(h.model.showThumbnail == false)
        #expect(!h.model.pdfSavesNoFile)

        h.prefs["type"] = "png"
        await h.model.setPreviewMode(.macOS)
        #expect(await eventually { await h.model.captureFormat == "png" })
        #expect(!h.model.pdfSavesNoFile)
    }

    @Test func nativeChangeWhileScreencaptureUIRunsAppliesFromTheNextScreenshot() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        await h.model.setPreviewMode(.clipShot)
        #expect(!h.model.appliesFromNextScreenshot, "screencaptureui not running: applies at once")

        h.screencaptureUIRunning = true
        await h.model.setPreviewMode(.macOS)
        #expect(h.model.appliesFromNextScreenshot)
        #expect(await h.statusRead())
        #expect(h.model.appliesFromNextScreenshot, "stays while screencaptureui runs")

        h.screencaptureUIRunning = false
        #expect(await eventually { await !h.model.appliesFromNextScreenshot })
    }

    @Test func folderErrorIsKeptUntilAFolderIsAccepted() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let missing = h.home.appendingPathComponent("Missing", isDirectory: true)
        await #expect(throws: FolderValidation.notFound) { try await h.model.setFolder(missing) }
        #expect(h.model.folderError == .notFound)

        try await h.model.setFolder(h.folder)
        #expect(h.model.folderError == nil)

        await #expect(throws: FolderValidation.notFound) { try await h.model.setFolder(missing) }
        h.model.clearFolderError()
        #expect(h.model.folderError == nil)
    }

    @Test func latestFollowsLastCopiedWithItsThumbnail() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(h.model.latest == nil)
        #expect(await h.start())
        try h.shoot("Screenshot 1.png", size: 40)
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 1.png" })
        let first = try #require(h.model.latest)
        #expect(first.thumbnail != nil)
        #expect(first.file == h.model.lastCopied)

        try h.shoot("Screenshot 2.png", size: 41)
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 2.png" })
        #expect(h.model.latest?.thumbnail != nil)
    }

    @Test func headerStateIsNeverTheCopiedFlash() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.iconState == .copied })
        #expect(h.model.headerState == .idle)
        h.preferences.copyEnabled = false
        #expect(h.model.headerState == .paused)
    }

    @Test func privacySettingsAndTrashOpenThroughTheWorkspace() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.openPrivacySettings()
        #expect(h.workspace.opened.last?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        #expect(await h.model.showTrash())
        #expect(h.workspace.opened.last?.lastPathComponent == ".Trash")
    }

    /// Show Trash after Clean up now: the folder's own Trash, else the home Trash, and false
    /// when neither can be opened, so Settings can say so instead of doing nothing.
    @Test func showTrashFallsBackToTheHomeTrashAndReportsFailure() async throws {
        let volumeTrash = URL(fileURLWithPath: "/Volumes/Shots/.Trashes/501", isDirectory: true)
        let homeTrash = URL(fileURLWithPath: "/Users/someone/.Trash", isDirectory: true)

        let both = try ModelHarness(locateTrash: { $0 == nil ? homeTrash : volumeTrash })
        defer { both.tearDown() }
        #expect(await both.start())
        #expect(await both.model.showTrash())
        #expect(both.workspace.opened == [volumeTrash], "the Trash of the screenshot folder's volume first")

        let homeOnly = try ModelHarness(locateTrash: { $0 == nil ? homeTrash : nil })
        defer { homeOnly.tearDown() }
        #expect(await homeOnly.start())
        #expect(await homeOnly.model.showTrash())
        #expect(homeOnly.workspace.opened == [homeTrash])

        let none = try ModelHarness(locateTrash: { _ in nil })
        defer { none.tearDown() }
        #expect(await none.start())
        #expect(await !none.model.showTrash())
        #expect(none.workspace.opened.isEmpty)
        #expect(await eventually { await Self.log(none).contains("show trash: no trash found") })

        let refused = try ModelHarness(locateTrash: { _ in homeTrash })
        defer { refused.tearDown() }
        refused.workspace.opens = false
        #expect(await refused.start())
        #expect(await !refused.model.showTrash())
        #expect(await eventually { await Self.log(refused).contains("show trash: open failed") })
        #expect(!Self.log(refused).contains("/"), "no path in the log line")
    }

    private static func log(_ h: ModelHarness) -> String {
        (try? String(contentsOf: h.logFile, encoding: .utf8)) ?? ""
    }
}
