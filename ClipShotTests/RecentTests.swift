import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClipShot

/// The popover's list of recent screenshots (Task 12i): the current one on top, then the 3
/// before it, newest first; Move to Trash with Undo (Addendum A6).
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

    /// The list as shown: names, the Undo strip as "undo:<name>".
    private func slots(_ h: ModelHarness) -> [String] {
        h.model.recentSlots.map { slot in
            if case .trashed(let file) = slot { "undo:" + file.url.lastPathComponent } else { slot.file.url.lastPathComponent }
        }
    }

    private func topRowHasThumbnail(_ h: ModelHarness) -> Bool {
        h.model.recent.first.flatMap { h.model.thumbnails[$0] } != nil
    }

    private func row(_ h: ModelHarness, _ name: String) throws -> CaptureFile {
        try #require(h.model.recent.first { $0.url.lastPathComponent == name })
    }

    // MARK: - Selection

    @Test func listShowsTheCurrentAndThreePreviousExistingNewestFirst() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [
            ("A.png", 60), ("B.png", 50), ("C.png", 40), ("D.png", 30), ("E.png", 20), ("Gone.png", 10),
        ])
        // Deleted, and renamed: neither is shown.
        try FileManager.default.moveItem(at: files[5].url, to: Fixtures.stagingDir.appendingPathComponent("Gone-\(UUID()).png"))
        try FileManager.default.moveItem(at: files[0].url, to: h.folder.appendingPathComponent("Renamed.png"))
        // In the ledger but in another folder: not this folder's list.
        let elsewhere = try Fixtures.makeDir()
        await h.ledger.adopt([try #require(CaptureFile.inspect(try Fixtures.write(named: "Other.png", in: elsewhere)))])
        #expect(await h.start())

        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })
        #expect(h.model.recent.allSatisfy { h.model.thumbnails[$0] != nil }, "thumbnails decoded before they show")

        // A new screenshot goes on top; the oldest row leaves, the list keeps four.
        try h.shoot("New.png")
        try await tracked(h, [("F.png", 5)])
        #expect(await eventually { await self.names(h.model.recent) == ["New.png", "F.png", "E.png", "D.png"] })
        #expect(RecentScreenshots.count == 4)
    }

    @Test func fewerScreenshotsFewerRowsAndNoneIsTheEmptyState() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.refreshRecent()
        #expect(await h.recentSettled())
        #expect(h.model.recent.isEmpty, "no screenshot yet: the quiet line")
        try h.shoot("Only.png")
        #expect(await eventually { await self.names(h.model.recent) == ["Only.png"] })
        #expect(RecentScreenshots.select(lastCopied: nil, ledger: [], folder: h.folder).isEmpty)
        #expect(RecentScreenshots.select(lastCopied: h.model.lastCopied, ledger: [], folder: nil).isEmpty)
    }

    /// Older screenshots the user adopted for cleanup are listed like the others, by when
    /// they were taken.
    @Test func adoptedScreenshotsAreListedByAge() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("Seen.png", 40)])
        try await tracked(h, [("Adopted.png", 20)], adopted: true)
        try await tracked(h, [("Newest.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["Newest.png", "Adopted.png", "Seen.png"] })
    }

    /// After a relaunch nothing has been copied yet, but the list is not empty: the ledger's
    /// screenshots, each with Copy.
    @Test func relaunchListsTheScreenshotsFromTheLedger() async throws {
        let first = try ModelHarness()
        #expect(await first.start())
        try first.shoot("Screenshot 1.png", size: 17)
        try first.shoot("Screenshot 2.png", size: 18)
        #expect(await eventually { await first.model.recent.first?.url.lastPathComponent == "Screenshot 2.png" })
        #expect(await eventually { await first.ledger.entries().count == 2 })
        first.tearDown()

        let relaunched = try ModelHarness(relaunching: first)
        defer { relaunched.tearDown() }
        #expect(relaunched.model.lastCopied == nil)
        #expect(await relaunched.start())
        #expect(await eventually { await self.names(relaunched.model.recent) == ["Screenshot 2.png", "Screenshot 1.png"] })
        #expect(relaunched.model.recent.allSatisfy { !relaunched.model.isOnClipboard($0) }, "every row offers Copy")
        #expect(relaunched.model.thumbnails[relaunched.model.recent[0]] != nil)
        #expect(relaunched.pasteboard.writes.isEmpty, "a relaunch copies nothing")
    }

    /// After a folder change the list never shows a file from the old folder.
    @Test func listFollowsTheWatchedFolder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await self.names(h.model.recent) == ["Screenshot 1.png"] })
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await h.model.setFolder(other)
        #expect(await eventually { await h.model.watchedFolder?.path == other.path })
        #expect(await eventually { await h.model.recent.isEmpty })
        #expect(h.model.lastCopied?.url.lastPathComponent == "Screenshot 1.png", "still the last copy")
    }

    // MARK: - Copy and Copy again

    /// Only the row whose screenshot ClipShot last put on the clipboard, while it is still
    /// there, says Copy again: the floating preview's Copied badge follows the same file.
    @Test func onlyTheScreenshotOnTheClipboardSaysCopyAgain() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 40), ("B.png", 30)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["B.png", "A.png"] })
        #expect(h.model.recent.allSatisfy { !h.model.isOnClipboard($0) }, "nothing copied yet: Copy on every row")

        // A new screenshot is copied: its row on top says Copy again.
        try h.shoot("New.png")
        #expect(await eventually { await self.names(h.model.recent) == ["New.png", "B.png", "A.png"] })
        #expect(h.model.isOnClipboard(try row(h, "New.png")))
        let b = try row(h, "B.png"), a = try row(h, "A.png")
        #expect(!h.model.isOnClipboard(b) && !h.model.isOnClipboard(a))

        // Copy on an older row: that row says Copy again now, the top row Copy; the order
        // stays by age.
        #expect(await h.model.copyAgain(file: try row(h, "A.png")))
        #expect(h.model.isOnClipboard(try row(h, "A.png")))
        #expect(!h.model.isOnClipboard(try row(h, "New.png")))
        #expect(names(h.model.recent) == ["New.png", "B.png", "A.png"])

        // Another app copies something: no row says Copy again.
        h.pasteboard.changeCount += 1
        h.model.forgetClipboardIfReplaced()
        #expect(h.model.recent.allSatisfy { !h.model.isOnClipboard($0) })
    }

    /// A row's Copy: that screenshot's PNG on the clipboard, with the menu bar's copy
    /// animation. An explicit Copy, so it works while copying is paused (Task 12b ruling),
    /// and paused copying writes nothing on its own meanwhile.
    @Test func copyFromARowCopiesThatScreenshotAndAnimates() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["C.png", "B.png", "A.png"] })
        #expect(h.model.flashPhase == 0, "nothing copied yet")
        #expect(h.pasteboard.writes.isEmpty)

        #expect(await h.model.copyAgain(file: try row(h, "A.png")))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: files[0].url)))
        #expect(h.model.flashPhase > 0, "the menu bar plays its copy animation")
        #expect(h.model.iconState == .copied)
        #expect(names(h.model.recent) == ["C.png", "B.png", "A.png"], "the list keeps its order")
        let timer = try #require(h.timer)
        timer.fire(PegFlash.steps - 1)
        #expect(h.model.flashPhase == 0)

        // Paused: a new screenshot is not copied, but a row's Copy still is.
        h.preferences.copyEnabled = false
        let writes = h.pasteboard.writes.count
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        let events = h.model.copyEventsHandled
        try h.shoot("D.png", size: 23)
        #expect(await h.copySettled(after: events))
        #expect(h.pasteboard.writes.count == writes, "paused: nothing is copied on its own")
        // The switch played Peg's pause moment; nothing played a copy.
        #expect(h.model.flashPhase == 0 || h.model.flashMoment == .pause, "paused: no copy animation on its own")
        #expect(await h.model.copyAgain(file: try row(h, "B.png")))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: files[1].url)))
        #expect(h.model.flashPhase > 0)
        #expect(h.model.flashMoment == .copied)
    }

    // MARK: - Move to Trash and Undo

    /// Any row: the Undo strip takes its place at once and the other rows stay where they
    /// were; the older screenshot read in meanwhile waits for Undo to be over. Undo puts the
    /// row back in the same step as the strip goes, so nothing in between is ever shown.
    @Test func trashLeavesTheUndoStripInPlaceAndUndoRestoresTheRow() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 50), ("B.png", 40), ("C.png", 30), ("D.png", 20), ("E.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })

        // A middle row.
        let c = try row(h, "C.png")
        try await h.model.trash(c)
        #expect(slots(h) == ["E.png", "D.png", "undo:C.png", "B.png"], "at once, before the folder is read")
        #expect(h.model.undoable?.original == c.url)
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "B.png", "A.png"] })
        #expect(slots(h) == ["E.png", "D.png", "undo:C.png", "B.png"], "A waits for Undo to be over")
        #expect(await h.model.undoTrash())
        #expect(slots(h) == ["E.png", "D.png", "C.png", "B.png"], "back in place in the strip's step")
        h.model.refreshRecent()
        #expect(await h.recentSettled())
        #expect(slots(h) == ["E.png", "D.png", "C.png", "B.png"])

        // The top row.
        try await h.model.trash(try row(h, "E.png"))
        #expect(slots(h) == ["undo:E.png", "D.png", "C.png", "B.png"])
        #expect(await h.model.undoTrash())
        #expect(slots(h) == ["E.png", "D.png", "C.png", "B.png"])

        // The last row.
        try await h.model.trash(try row(h, "B.png"))
        #expect(slots(h) == ["E.png", "D.png", "C.png", "undo:B.png"])
        #expect(await eventually { await self.names(h.model.recent).last == "A.png" })
        #expect(slots(h) == ["E.png", "D.png", "C.png", "undo:B.png"])
    }

    /// Once Undo is over, the strip closes: the rows under it move up and the older
    /// screenshot fills the last row; the rows above stay.
    @Test func whenUndoEndsTheOlderScreenshotFillsTheLastRow() async throws {
        let h = try ModelHarness(undoLifetime: .milliseconds(300))
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 50), ("B.png", 40), ("C.png", 30), ("D.png", 20), ("E.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 4 })
        try await h.model.trash(try row(h, "D.png"))
        #expect(slots(h) == ["E.png", "undo:D.png", "C.png", "B.png"])
        #expect(await eventually(timeout: .seconds(2)) { await h.model.undoable == nil })
        #expect(await eventually { await self.slots(h) == ["E.png", "C.png", "B.png", "A.png"] })
    }

    /// The strip on the last row, then a new screenshot: the strip keeps the last place
    /// rather than jumping to the top. Undo puts the file back in time order, below the
    /// four rows now, and still says so.
    @Test func aNewScreenshotDuringUndoLeavesTheStripAtTheBottom() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 50), ("B.png", 40), ("C.png", 30), ("D.png", 20), ("E.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })
        try await h.model.trash(try row(h, "B.png"))
        #expect(slots(h) == ["E.png", "D.png", "C.png", "undo:B.png"])

        try h.shoot("New.png")
        #expect(await eventually { await self.names(h.model.recent) == ["New.png", "E.png", "D.png", "C.png"] })
        #expect(slots(h) == ["New.png", "E.png", "D.png", "undo:B.png"], "still at the bottom, not on top")

        #expect(await h.model.undoTrash())
        #expect(slots(h) == ["New.png", "E.png", "D.png", "C.png"], "back in time order, below the four rows")
        #expect(h.announced.last == Copy.Recent.putBack.key)
        #expect(RT.exists(h.folder.appendingPathComponent("B.png")))
    }

    /// A screenshot that was not among the rows (moved from its floating preview, older than
    /// all four) gets its strip on top.
    @Test func aFileThatWasNotListedGetsItsStripOnTop() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [("Old.png", 90), ("A.png", 40), ("B.png", 30), ("C.png", 20), ("D.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["D.png", "C.png", "B.png", "A.png"] })
        try await h.model.trash(files[0])
        #expect(h.model.undoable?.listed == false)
        #expect(slots(h) == ["undo:Old.png", "D.png", "C.png", "B.png"])
    }

    /// Undo pressed again while the first one is still putting the file back (a double
    /// click, ⌘Z repeated): the same Undo, so no failure, no alert, no note.
    @Test func aRepeatedUndoDuringTheRestoreIsSilent() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 30), ("B.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 2 })
        try await h.model.trash(files[0])
        async let first: Void = h.model.putBack()
        async let second: Void = h.model.putBack()
        _ = await (first, second)
        #expect(RT.exists(files[0].url))
        #expect(h.alerts == 0, "no alert sound")
        #expect(h.model.actionNote == nil, "no failure note")
        #expect(!h.announced.contains(Copy.Failure.undoFailed.key))
        #expect(slots(h) == ["B.png", "A.png"])
    }

    /// Where the strip goes: the row's place in time order, at most four places; a trashed
    /// file older than all four rows (a floating preview's) on top.
    @Test func undoStripPlace() throws {
        let now = Date()
        func file(_ name: String, _ minutes: Double) -> CaptureFile {
            CaptureFile(
                url: URL(fileURLWithPath: "/S/\(name)"), created: now.addingTimeInterval(-minutes * 60),
                modified: now, size: 1, resourceID: Data(name.utf8), isScreenshot: true)
        }
        func names(_ slots: [RecentSlot]) -> [String] {
            slots.map { slot in
                if case .trashed(let f) = slot { "undo:" + f.url.lastPathComponent } else { slot.file.url.lastPathComponent }
            }
        }
        let rows = [file("E", 10), file("D", 20), file("B", 40), file("A", 50)]
        #expect(names(RecentScreenshots.slots(files: rows, trashed: nil)) == ["E", "D", "B", "A"])
        #expect(names(RecentScreenshots.slots(files: rows, trashed: file("C", 30))) == ["E", "D", "undo:C", "B"])
        #expect(names(RecentScreenshots.slots(files: rows, trashed: file("New", 1))) == ["undo:New", "E", "D", "B"])
        #expect(names(RecentScreenshots.slots(files: rows, trashed: file("Old", 90))) == ["undo:Old", "E", "D", "B"],
                "not among the rows: on top")
        #expect(names(RecentScreenshots.slots(files: Array(rows.prefix(2)), trashed: file("Old", 90))) == ["E", "D", "undo:Old"],
                "fewer rows: where it was")
        #expect(names(RecentScreenshots.slots(files: [], trashed: file("Only", 1))) == ["undo:Only"])
        #expect(names(RecentScreenshots.slots(files: rows, trashed: file("Old", 90), wasListed: true)) == ["E", "D", "B", "undo:Old"],
                "a row that was listed keeps the last place")
        #expect(names(RecentScreenshots.slots(files: rows, trashed: file("C", 30), wasListed: true)) == ["E", "D", "undo:C", "B"],
                "in its natural place when there is room")
        #expect(RecentScreenshots.inserting(file("C", 30), into: rows).map(\.url.lastPathComponent) == ["E", "D", "C", "B"])
    }

    @Test func trashFromFloatingPreviewUpdatesTheList() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        try await tracked(h, [("Earlier.png", 30)])
        #expect(await h.start())
        #expect(await eventually { await h.model.previewModeKnown })
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.previews.visible.count == 1 })
        #expect(await eventually { await self.names(h.model.recent) == ["Screenshot 1.png", "Earlier.png"] })
        let shown = try #require(h.model.previews.visible.first?.file)
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(shown.url), resourceID: shown.resourceID) })

        // The preview's Move to Trash: the list never keeps the trashed file.
        try await h.model.trash(shown)
        #expect(names(h.model.recent) == ["Earlier.png"])
        #expect(slots(h) == ["undo:Screenshot 1.png", "Earlier.png"], "the strip where its row was, on top")
        #expect(h.model.previews.visible.isEmpty)
        h.model.refreshRecent()
        #expect(await h.recentSettled())
        #expect(names(h.model.recent) == ["Earlier.png"], "a refresh does not bring it back")

        #expect(await h.model.undoTrash())
        #expect(slots(h) == ["Screenshot 1.png", "Earlier.png"])
        #expect(await eventually { await self.names(h.model.recent) == ["Screenshot 1.png", "Earlier.png"] })
    }

    /// On a manual clock, so "not yet over" is checked a moment before the end, exactly.
    @Test func undoShownFiveSeconds() async throws {
        #expect(AppModel.defaultUndoLifetime == .seconds(5))
        let clock = ManualTimerClock()
        let h = try ModelHarness(timerClock: clock)
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 3 })

        // One Undo at a time: a second trash replaces the first one's.
        try await h.model.trash(files[0])
        clock.advance(by: .milliseconds(2_500))
        try await h.model.trash(files[1])
        #expect(h.model.undoable?.original == files[1].url)
        // The first one's time is up; its timer wakes and must not end the second's.
        clock.advance(by: .milliseconds(2_500))
        #expect(await eventually { clock.waiting == 1 }, "only the second's timer still waits")
        #expect(h.model.undoable?.original == files[1].url)
        clock.advance(by: .milliseconds(2_499))
        #expect(h.model.undoable?.original == files[1].url, "a moment before its 5 s")

        // After its time, Undo is gone.
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await h.model.undoable == nil })
        #expect(await h.model.undoTrash() == false)
        #expect(!RT.exists(files[1].url))
        #expect(!RT.exists(files[0].url))
    }

    /// Move to Trash the moment a new screenshot is listed: its ledger entry, written off the
    /// main actor, is waited for rather than refused.
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
        let events = h.model.copyEventsHandled
        let old = Date().addingTimeInterval(-3_600)
        let replacement = try Fixtures.write(
            named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 30), in: h.folder, created: old, modified: old)
        let replaced = try #require(CaptureFile.inspect(replacement))
        // Past the event's pass and all its rescans.
        #expect(await h.copySettled(after: events))
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
        let renameEvents = h.model.copyEventsHandled
        try FileManager.default.moveItem(at: url2, to: renamed)
        // The session keeps a poll pass running; the rename's own pass and rescans are what
        // matter.
        #expect(await h.copySettled(after: renameEvents))
        #expect(await !h.ledger.contains(path: FolderGuard.canonicalPath(renamed), resourceID: file2.resourceID))
    }

    // MARK: - Thumbnails

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
        #expect(await eventually { await self.names(h.model.recent) == ["Writing.png"] })
        h.model.refreshRecent()
        #expect(await h.recentSettled())
        #expect(h.model.thumbnails[h.model.recent[0]] == nil, "a file not written yet has no thumbnail")

        // The rest of the file lands in place: the same file, a new version.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: png)
        try handle.close()
        let complete = try #require(CaptureFile.inspect(url))
        #expect(complete.resourceID == partial.resourceID)
        h.model.refreshRecent()
        #expect(await eventually { await self.topRowHasThumbnail(h) })
    }
}

/// What a row shows of a screenshot's name: the time at its end stays whole.
struct FileNameLabelTests {
    @Test func theTimeIsTheTail() throws {
        let en = try #require(FileNameLabel.split("Screenshot 2026-10-19 at 09.41.12.png"))
        #expect(en == FileNameLabel.Parts(head: "Screenshot 2026-10-19 at", tail: " 09.41.12.png"))
        let us = try #require(FileNameLabel.split("Screenshot 2026-10-19 at 9.41.12\u{202F}AM.png"))
        #expect(us.tail == " 9.41.12\u{202F}AM.png")
        let numbered = try #require(FileNameLabel.split("Bildschirmfoto 2026-10-19 um 09.41.12 (2).png"))
        #expect(numbered.tail == " 09.41.12 (2).png")
        let es = try #require(FileNameLabel.split("Captura de pantalla 2026-10-19 a las 9.41.12.png"))
        #expect(es.head == "Captura de pantalla 2026-10-19 a las")
        #expect(FileNameLabel.split("Kept.png") == nil, "no time: cut in the middle as usual")
        #expect(FileNameLabel.split("09.41.12.png") == nil, "nothing before the time to cut")
    }

    /// In the row's text column the time is whole, whatever the head: the head gives way.
    @MainActor
    @Test func aLongNameKeepsItsTime() async throws {
        let name = "Captura de pantalla 2026-10-19 a las 9.41.12.png"
        let parts = try #require(FileNameLabel.split(name))
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let tail = (parts.tail as NSString).size(withAttributes: [.font: font]).width
        let label = NSHostingView(rootView: FileNameLabel(name: name).font(Design.Typography.cardTitle)
            .frame(width: RecentRow.textWidth, alignment: .leading))
        label.frame.size = label.fittingSize
        #expect(tail < RecentRow.textWidth / 2, "the tail takes \(tail) of \(RecentRow.textWidth) pt")
        #expect(label.fittingSize.height < 20, "one line")
    }
}

/// VoiceOver: each row is one element named by its file, then its age, size and place in
/// the list, with the row's actions by name; the list is labelled as a group.
@MainActor
struct RecentAccessibilityTests {
    @Test func rowValueSaysAgeSizeAndPosition() {
        var value = Copy.Recent.rowValue(age: "Just now", size: "1.2 MB", position: 1, count: 4)
        value.locale = Locale(identifier: "en")
        #expect(String(localized: value) == "Just now, 1.2 MB, 1 of 4")
        let expected = ["sk": "1 z\u{00A0}4", "cs": "1 z\u{00A0}4", "de": "1 von 4", "es": "1 de 4", "fr": "1 sur 4"]
        for (id, position) in expected {
            var resource = Copy.Recent.rowValue(age: "x", size: "y", position: 1, count: 4)
            resource.locale = Locale(identifier: id)
            #expect(String(localized: resource) == "x, y, \(position)", "\(id)")
        }
    }

    /// The row's named actions, as its right-click menu has them: Copy again only on the
    /// row whose screenshot is on the clipboard.
    @Test func actionsAreNamedAsThePills() {
        func titles(_ onClipboard: Bool) -> [String] {
            RecentRow.Action.allCases.map {
                var title = RecentRow.title($0, onClipboard: onClipboard)
                title.locale = Locale(identifier: "en")
                return String(localized: title)
            }
        }
        #expect(titles(false) == ["Copy", "Edit with Markup", "Show in Finder", "Move to Trash"])
        #expect(titles(true) == ["Copy again", "Edit with Markup", "Show in Finder", "Move to Trash"])
    }

    /// After the file name: the age as the row shows it, the size, and the place in the list.
    @Test func valueSaysAgeSizeAndPlace() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let en = Locale(identifier: "en_US")
        func value(_ age: TimeInterval, _ position: Int, _ count: Int) -> String {
            var resource = RecentRow.accessibilityValue(
                created: now.addingTimeInterval(-age), size: "1.2 MB", position: position, count: count, now: now, locale: en)
            resource.locale = en
            return String(localized: resource)
        }
        #expect(value(10, 1, 4) == "Just now, 1.2 MB, 1 of 4")
        #expect(value(41 * 60, 4, 4) == "41 minutes ago, 1.2 MB, 4 of 4")
        #expect(value(26 * 3_600, 2, 3) == "Yesterday, 1.2 MB, 2 of 3")
    }
}

/// The row's keyboard: Space and Return open Markup from the thumbnail only, never while
/// one of its pills has focus (that pill takes the key).
@MainActor
struct RecentRowKeyTests {
    @Test func onlyTheThumbnailOpensMarkup() {
        #expect(RecentRow.keyOpensMarkup(focus: .thumbnail))
        #expect(!RecentRow.keyOpensMarkup(focus: .copy))
        #expect(!RecentRow.keyOpensMarkup(focus: .reveal))
        #expect(!RecentRow.keyOpensMarkup(focus: .trash))
        #expect(!RecentRow.keyOpensMarkup(focus: nil))
    }
}
