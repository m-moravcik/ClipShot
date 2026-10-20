import Foundation
import Testing
@testable import ClipShot

/// The popover's latest card, the strip of earlier screenshots, and Move to Trash with Undo
/// (spec Addendum A5, A6).
@MainActor
struct RecentTests {
    /// Screenshots ClipShot saw being taken, `minutes` old each, in the ledger; `adopted`:
    /// older ones the user added to the cleanup instead.
    @discardableResult
    private func tracked(
        _ h: ModelHarness, _ names: [(String, Double)], adopted: Bool = false
    ) async throws -> [CaptureFile] {
        let now = Date()
        var files: [CaptureFile] = []
        for (name, minutes) in names {
            let date = now.addingTimeInterval(-minutes * 60)
            let url = try Fixtures.write(named: name, in: h.folder, created: date, modified: date)
            files.append(try #require(CaptureFile.inspect(url)))
        }
        if adopted {
            await h.ledger.adopt(files)
        } else {
            for file in files { await h.ledger.record(file) }
        }
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

    /// The strip's Copy: that screenshot's PNG on the clipboard, through the card's Copy again,
    /// with the menu bar's copy animation. An explicit Copy, so it works while copying is
    /// paused (Task 12b ruling), and paused copying writes nothing on its own meanwhile.
    @Test func copyFromStripCopiesThatScreenshotAndAnimates() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["B.png", "A.png"] })
        #expect(h.model.flashPhase == 0, "nothing copied yet")
        #expect(h.pasteboard.writes.isEmpty)

        let a = try #require(h.model.recent.last)
        #expect(await h.model.copyAgain(file: a))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: files[0].url)))
        #expect(h.model.flashPhase > 0, "the menu bar plays its copy animation")
        #expect(h.model.iconState == .copied)
        #expect(h.model.latest?.file.url.lastPathComponent == "C.png", "the card keeps its screenshot")
        let timer = try #require(h.timer)
        timer.fire(CopiedFlash.steps - 1)
        #expect(h.model.flashPhase == 0)

        // Paused: a new screenshot is not copied, but the strip's Copy still is.
        h.preferences.copyEnabled = false
        let writes = h.pasteboard.writes.count
        try h.shoot("D.png", size: 23)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.pasteboard.writes.count == writes, "paused: nothing is copied on its own")
        #expect(h.model.flashPhase == 0, "paused: no copy animation on its own")
        let b = try #require(h.model.recent.first { $0.url.lastPathComponent == "B.png" })
        #expect(await h.model.copyAgain(file: b))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: files[1].url)))
        #expect(h.model.flashPhase > 0)
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

    // MARK: - The card

    /// Nothing copied this session: the card shows the newest screenshot ClipShot saw being
    /// taken, with Copy rather than Copy again; never an adopted older file.
    @Test func cardFallbackIsObservedOnlyAndSaysCopy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("Adopted.png", 30)], adopted: true)
        #expect(await h.start())
        h.model.refreshRecent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.model.latest == nil, "only an adopted file: No screenshot copied yet")
        #expect(names(h.model.recent) == ["Adopted.png"], "the strip still lists it")

        try await tracked(h, [("Seen.png", 40)])
        h.model.refreshRecent()
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Seen.png" })
        #expect(h.model.latest?.isLastCopied == false)
        #expect(names(h.model.recent) == ["Adopted.png"])

        try h.shoot("Copied.png")
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Copied.png" })
        #expect(h.model.latest?.isLastCopied == true)
    }

    /// After a relaunch nothing has been copied yet, but the card is not empty: it shows the
    /// newest screenshot in the ledger, with Copy (the card fallback).
    @Test func relaunchShowsTheLatestScreenshotFromTheLedger() async throws {
        let first = try ModelHarness()
        #expect(await first.start())
        try first.shoot("Screenshot 1.png", size: 17)
        try first.shoot("Screenshot 2.png", size: 18)
        #expect(await eventually { await first.model.latest?.file.url.lastPathComponent == "Screenshot 2.png" })
        #expect(await eventually { await first.ledger.entries().count == 2 })
        first.tearDown()

        let relaunched = try ModelHarness(relaunching: first)
        defer { relaunched.tearDown() }
        #expect(relaunched.model.lastCopied == nil)
        #expect(await relaunched.start())
        #expect(await eventually { await relaunched.model.latest?.file.url.lastPathComponent == "Screenshot 2.png" })
        #expect(relaunched.model.latest?.isLastCopied == false, "the card offers Copy, not Copy again")
        #expect(relaunched.model.latest?.thumbnail != nil)
        #expect(names(relaunched.model.recent) == ["Screenshot 1.png"])
        #expect(relaunched.pasteboard.writes.isEmpty, "a relaunch copies nothing")
    }

    /// The card's file goes to the Trash: the strip's newest screenshot ClipShot saw moves up
    /// at once, never an adopted older file, not even until the next refresh corrects it.
    @Test func trashedCardIsReplacedByAnObservedScreenshotOnly() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("Seen.png", 40)])
        try await tracked(h, [("Adopted.png", 20)], adopted: true)
        try await tracked(h, [("Card.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 2 })
        let card = try #require(h.model.latest?.file)
        #expect(card.url.lastPathComponent == "Card.png")
        #expect(names(h.model.recent) == ["Adopted.png", "Seen.png"])

        try await h.model.trash(card)
        #expect(h.model.latest?.file.url.lastPathComponent == "Seen.png", "at once, skipping the adopted file")
        #expect(names(h.model.recent) == ["Adopted.png"])
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.model.latest?.file.url.lastPathComponent == "Seen.png")
        #expect(names(h.model.recent) == ["Adopted.png"])

        // Only adopted files left: the card empties at once, the strip keeps them.
        let seen = try #require(h.model.latest?.file)
        try await h.model.trash(seen)
        #expect(h.model.latest == nil)
        #expect(names(h.model.recent) == ["Adopted.png"])
    }

    /// A thumbnail that could not be decoded while the file was still being written is tried
    /// again once the file changes: the failure belongs to that version of the file (same
    /// resource ID, size and modification date), not to its path.
    @Test func undecodableThumbnailIsRetriedWhenTheFileChanges() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let png = Fixtures.pngImage(size: 24)
        let url = try Fixtures.write(named: "Writing.png", contents: Data(), in: h.folder)
        let partial = try #require(CaptureFile.inspect(url))
        await h.ledger.record(partial)
        #expect(await h.start())
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Writing.png" })
        h.model.refreshRecent()
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.model.latest?.thumbnail == nil, "a file not written yet has no thumbnail")

        // The rest of the file lands in place: the same file, a new version.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: png)
        try handle.close()
        let complete = try #require(CaptureFile.inspect(url))
        #expect(complete.resourceID == partial.resourceID)
        h.model.refreshRecent()
        #expect(await eventually { await h.model.latest?.thumbnail != nil })
    }

    /// After a folder change the card never shows a file from the old folder.
    @Test func cardFollowsTheWatchedFolder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.latest?.file.url.lastPathComponent == "Screenshot 1.png" })
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await h.model.setFolder(other)
        #expect(await eventually { await h.model.watchedFolder?.path == other.path })
        #expect(await eventually { await h.model.latest == nil })
        #expect(h.model.lastCopied?.url.lastPathComponent == "Screenshot 1.png", "still the last copy")
    }

    /// Move to Trash the moment the card shows a new screenshot: its ledger entry, written
    /// off the main actor, is waited for rather than refused.
    @Test func trashRightAfterCaptureIsNotRefused() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        for index in 1...5 {
            let url = try h.shoot("Screenshot \(index).png")
            let deadline = ContinuousClock.now + .seconds(5)
            while h.model.lastCopied?.url.lastPathComponent != url.lastPathComponent, ContinuousClock.now < deadline {
                await Task.yield()
            }
            let file = try #require(h.model.lastCopied)
            try await h.model.trash(file)
            #expect(!RT.exists(url))
        }
    }
}
