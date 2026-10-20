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
        timer.fire(CopiedFlash.steps - 1)
        #expect(h.model.flashPhase == 0)

        // Paused: a new screenshot is not copied, but a row's Copy still is.
        h.preferences.copyEnabled = false
        let writes = h.pasteboard.writes.count
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        let events = h.model.copyEventsHandled
        try h.shoot("D.png", size: 23)
        #expect(await h.copySettled(after: events))
        #expect(h.pasteboard.writes.count == writes, "paused: nothing is copied on its own")
        #expect(h.model.flashPhase == 0, "paused: no copy animation on its own")
        #expect(await h.model.copyAgain(file: try row(h, "B.png")))
        #expect(h.pasteboard.writes.last == (try Data(contentsOf: files[1].url)))
        #expect(h.model.flashPhase > 0)
    }

    // MARK: - Move to Trash and Undo

    /// Any row: it leaves at once and the rows under it move up; the next read fills the last
    /// row from an older screenshot; Undo puts it back in its place.
    @Test func trashCollapsesTheRowAndUndoRestoresTheOrder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await tracked(h, [("A.png", 50), ("B.png", 40), ("C.png", 30), ("D.png", 20), ("E.png", 10)])
        #expect(await h.start())
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })

        // A middle row.
        let c = try row(h, "C.png")
        try await h.model.trash(c)
        #expect(names(h.model.recent) == ["E.png", "D.png", "B.png"], "at once, before the folder is read")
        #expect(h.model.undoable?.original == c.url)
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "B.png", "A.png"] })
        #expect(await h.model.undoTrash())
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })

        // The top row: the one under it moves up to the top.
        let e = try row(h, "E.png")
        try await h.model.trash(e)
        #expect(names(h.model.recent) == ["D.png", "C.png", "B.png"])
        #expect(await eventually { await self.names(h.model.recent) == ["D.png", "C.png", "B.png", "A.png"] })
        #expect(await h.model.undoTrash())
        #expect(await eventually { await self.names(h.model.recent) == ["E.png", "D.png", "C.png", "B.png"] })
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
        #expect(h.model.previews.visible.isEmpty)
        h.model.refreshRecent()
        #expect(await h.recentSettled())
        #expect(names(h.model.recent) == ["Earlier.png"], "a refresh does not bring it back")

        #expect(await h.model.undoTrash())
        #expect(await eventually { await self.names(h.model.recent) == ["Screenshot 1.png", "Earlier.png"] })
    }

    @Test func undoShownFiveSeconds() async throws {
        #expect(AppModel.defaultUndoLifetime == .seconds(5))
        let h = try ModelHarness(undoLifetime: .milliseconds(400))
        defer { h.tearDown() }
        let files = try await tracked(h, [("A.png", 40), ("B.png", 30), ("C.png", 20)])
        #expect(await h.start())
        #expect(await eventually { await h.model.recent.count == 3 })

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
