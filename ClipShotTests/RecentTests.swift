import Foundation
import Testing
@testable import ClipShot

/// The popover's latest card, the strip of earlier screenshots, and Move to Trash with Undo
/// (spec Addendum A5, A6).
@MainActor
struct RecentTests {
    /// Screenshots ClipShot saw, `minutes` old each, in the ledger.
    @discardableResult
    private func tracked(_ h: ModelHarness, _ names: [(String, Double)]) async throws -> [CaptureFile] {
        let now = Date()
        var files: [CaptureFile] = []
        for (name, minutes) in names {
            let date = now.addingTimeInterval(-minutes * 60)
            let url = try Fixtures.write(named: name, in: h.folder, created: date, modified: date)
            files.append(try #require(CaptureFile.inspect(url)))
        }
        await h.ledger.adopt(files)
        return files
    }

    private func names(_ files: [CaptureFile]) -> [String] { files.map(\.url.lastPathComponent) }

    @Test func recentListsPreviousFourExistingNewestFirst() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [
            ("A.png", 60), ("B.png", 50), ("C.png", 40), ("D.png", 30), ("E.png", 20), ("Gone.png", 10),
        ])
        // Deleted, and renamed: neither is shown.
        try FileManager.default.moveItem(at: files[5].url, to: Fixtures.stagingDir.appendingPathComponent("Gone-\(UUID()).png"))
        try FileManager.default.moveItem(at: files[0].url, to: h.folder.appendingPathComponent("Renamed.png"))
        // In the ledger but in another folder: not this folder's strip.
        let elsewhere = try Fixtures.makeDir()
        await h.ledger.adopt([try #require(CaptureFile.inspect(try Fixtures.write(named: "Other.png", in: elsewhere)))])
        #expect(await h.start())

        // Nothing copied since launch: the newest existing one is the card.
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "E.png" })
        #expect(names(h.model.recent) == ["D.png", "C.png", "B.png"])
        #expect(h.model.recent.allSatisfy { h.model.thumbnails[$0] != nil }, "thumbnails decoded before they show")

        // A new screenshot takes the card; the previous one leads the strip, which keeps four.
        try h.shoot("New.png")
        try await tracked(h, [("F.png", 5)])
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "New.png" })
        #expect(await eventually { await self.names(h.model.recent) == ["F.png", "E.png", "D.png", "C.png"] })
    }

    @Test func recentHidesWhenEmpty() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Only.png")
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Only.png" })
        h.model.refreshRecent()
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.model.recent.isEmpty, "the strip is hidden: the only screenshot is the card")
        #expect(RecentScreenshots.select(lastCopied: nil, ledger: [], folder: h.folder) == .init(card: nil, recent: []))
    }

    @Test func trashFromStripUpdatesCardAndStrip() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 2 })
        let card = try #require(h.model.latest?.file)
        #expect(card.url.lastPathComponent == "C.png")

        // From the strip: gone from it at once, the card stays.
        let b = try #require(h.model.recent.first)
        try await h.model.trash(b)
        #expect(names(h.model.recent) == ["A.png"])
        #expect(h.model.latest?.file == card)
        #expect(h.model.undoable?.original == b.url)

        // Undo puts it back where it was.
        #expect(await h.model.undoTrash())
        #expect(await eventually { await self.names(h.model.recent) == ["B.png", "A.png"] })

        // The card's own file: the strip's newest moves up into the card at once.
        try await h.model.trash(card)
        #expect(h.model.latest?.file.url.lastPathComponent == "B.png")
        #expect(names(h.model.recent) == ["A.png"])
        #expect(await h.model.undoTrash())
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "C.png" })
        #expect(await eventually { await self.names(h.model.recent) == ["B.png", "A.png"] })
    }

    @Test func trashFromFloatingPreviewUpdatesCardAndStrip() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        try await tracked(h, [("Earlier.png", 30)])
        #expect(await h.start())
        #expect(await eventually { await h.model.previewModeKnown })
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.previews.visible.count == 1 })
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 1.png" })
        #expect(await eventually { await self.names(h.model.recent) == ["Earlier.png"] })
        let shown = try #require(h.model.previews.visible.first?.file)
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(shown.url), resourceID: shown.resourceID) })

        // The preview's Move to Trash: the card never keeps the trashed file.
        try await h.model.trash(shown)
        #expect(h.model.latest?.file.url.lastPathComponent == "Earlier.png")
        #expect(h.model.recent.isEmpty)
        #expect(h.model.previews.visible.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.model.latest?.file.url.lastPathComponent == "Earlier.png", "a refresh does not bring it back")

        #expect(await h.model.undoTrash())
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 1.png" })
        #expect(await eventually { await self.names(h.model.recent) == ["Earlier.png"] })
    }

    @Test func undoShownFiveSeconds() async throws {
        #expect(AppModel.defaultUndoLifetime == .seconds(5))
        let h = try ModelHarness(undoLifetime: .milliseconds(400))
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 2 })

        // One Undo at a time: a second trash replaces the first one's.
        try await h.model.trash(files[0])
        try await Task.sleep(for: .milliseconds(250))
        try await h.model.trash(files[1])
        #expect(h.model.undoable?.original == files[1].url)
        // The first one's time is up, the second's is not.
        try await Task.sleep(for: .milliseconds(250))
        #expect(h.model.undoable?.original == files[1].url)

        // After its time, Undo is gone.
        #expect(await eventually(timeout: .seconds(2)) { await h.model.undoable == nil })
        #expect(await h.model.undoTrash() == false)
        #expect(!RT.exists(files[1].url))
        #expect(!RT.exists(files[0].url))
    }

    // MARK: - Edits saved by replacing the file

    @Test func editReplaceKeepsLedgerEntry() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        // A screenshot from an hour ago: only the edit session can keep its replacement tracked.
        let file = try #require(try await tracked(h, [("Screenshot 1.png", 60)]).first)
        let url = file.url
        #expect(await h.start())

        // Open in Markup (Preview never says when it closes: the session stays open).
        h.markupResult = .openedInPreview
        h.model.markup(file)
        // Saved by replacing: a new inode at the same path, as old as the original.
        let edited = try Fixtures.write(
            named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 30), in: h.folder,
            created: file.created, modified: Date())
        let replaced = try #require(CaptureFile.inspect(edited))
        #expect(replaced.resourceID != file.resourceID)

        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: replaced.resourceID) })
        try await h.model.trash(replaced)
        #expect(!RT.exists(url))
    }

    @Test func replaceOutsideSessionLeavesLedger() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })

        // No edit session: an older file put in its place is not ClipShot's screenshot.
        let old = Date().addingTimeInterval(-3_600)
        let replacement = try Fixtures.write(
            named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 30), in: h.folder, created: old, modified: old)
        let replaced = try #require(CaptureFile.inspect(replacement))
        // Past the event pass and its first rescans.
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await !h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: replaced.resourceID))
        await #expect(throws: AppModel.TrashError.notTracked) { try await h.model.trash(replaced) }
        #expect(RT.exists(url))

        // Renamed inside a session: still leaves the ledger.
        let url2 = try h.shoot("Screenshot 2.png")
        let file2 = try #require(CaptureFile.inspect(url2))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url2), resourceID: file2.resourceID) })
        h.markupResult = .openedInPreview
        h.model.markup(file2)
        let renamed = h.folder.appendingPathComponent("Kept.png")
        try FileManager.default.moveItem(at: url2, to: renamed)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(await !h.ledger.contains(path: FolderGuard.canonicalPath(renamed), resourceID: file2.resourceID))
    }
}
