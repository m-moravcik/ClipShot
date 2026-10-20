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
        try? await Task.sleep(for: .milliseconds(300))
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
        try? await Task.sleep(for: .milliseconds(300))
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
        await h.model.showTrash()
        #expect(h.workspace.opened.last?.lastPathComponent == ".Trash")
    }
}
