import Foundation
import Testing
@testable import ClipShot

/// Move to Trash and Undo where the user acted (U7, U10, U11): Undo on the floating preview
/// itself, a failure said in words (with the alert sound as well, never instead), and
/// VoiceOver told about both.
@MainActor
struct UndoAndFailureTests {
    /// A screenshot ClipShot saw being taken, with its floating preview on show.
    private func shotWithPreview(_ h: ModelHarness, _ name: String = "Screenshot 1.png") async throws -> (CaptureFile, UUID) {
        if h.prefs["show-thumbnail"] as? Bool != false {
            h.prefs["show-thumbnail"] = false
            #expect(await eventually { await h.model.previewMode == .clipShot })
        }
        let url = try h.shoot(name)
        #expect(await eventually { await h.model.previews.visible.contains { $0.file.url == url } })
        let item = try #require(h.model.previews.visible.first { $0.file.url == url })
        await h.model.ledgerSettled()
        return (item.file, item.id)
    }

    @Test func trashFromThePreviewOffersUndoOnThePreviewItself() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (file, id) = try await shotWithPreview(h)

        await h.model.moveToTrash(file, fromPreview: id)
        #expect(!RT.exists(file.url))
        let item = try #require(h.model.previews.visible.first { $0.id == id })
        #expect(item.trashed, "the preview stays, as Moved to the Trash with Undo")
        #expect(h.model.undoables.map(\.file) == [file], "the popover offers the same Undo")
        #expect(!h.model.previews.showsCopied(item), "an Undo preview says no Copied")
        #expect(h.announced.contains(Copy.Recent.moved.key))

        await h.model.putBack(file, fromPreview: id)
        #expect(RT.exists(file.url))
        #expect(h.model.undoables.isEmpty)
        #expect(!h.model.previews.visible.contains { $0.id == id }, "used: the Undo preview leaves")
        #expect(h.announced.contains(Copy.Recent.putBack.key))
        #expect(h.alerts == 0)
    }

    @Test func thePreviewsUndoEndsWithTheModelsUndo() async throws {
        let h = try ModelHarness(undoLifetime: .milliseconds(300))
        defer { h.tearDown() }
        #expect(await h.start())
        let (file, id) = try await shotWithPreview(h)
        await h.model.moveToTrash(file, fromPreview: id)
        #expect(h.model.previews.visible.first { $0.id == id }?.trashed == true)
        #expect(await eventually { await h.model.undoables.isEmpty })
        #expect(!h.model.previews.visible.contains { $0.id == id })
    }

    /// Each preview keeps its own Undo (0.9.2): a newer move leaves an older preview's Undo
    /// on offer, and each preview puts back only its own screenshot.
    @Test func eachPreviewKeepsAndUsesItsOwnUndo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (first, firstID) = try await shotWithPreview(h, "Screenshot 1.png")
        let (second, secondID) = try await shotWithPreview(h, "Screenshot 2.png")
        await h.model.moveToTrash(first, fromPreview: firstID)
        await h.model.moveToTrash(second, fromPreview: secondID)
        #expect(h.model.previews.visible.filter { $0.trashed }.map(\.id) == [firstID, secondID], "both offer Undo")
        #expect(h.model.undoables.map(\.file) == [first, second])

        await h.model.putBack(first, fromPreview: firstID)
        #expect(RT.exists(first.url), "the older preview put back its own screenshot")
        #expect(!RT.exists(second.url), "the newer screenshot stays in the Trash")
        #expect(!h.model.previews.visible.contains { $0.id == firstID }, "used: its Undo preview leaves")
        #expect(h.model.previews.visible.first { $0.id == secondID }?.trashed == true, "the other one still offers Undo")
        #expect(h.model.undoables.map(\.file) == [second])
        #expect(h.alerts == 0)
    }

    /// A failed Undo on one preview is said on that preview and ends only its Undo.
    @Test func aFailedUndoOnOnePreviewLeavesTheOthers() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (first, firstID) = try await shotWithPreview(h, "Screenshot 1.png")
        let (second, secondID) = try await shotWithPreview(h, "Screenshot 2.png")
        await h.model.moveToTrash(first, fromPreview: firstID)
        await h.model.moveToTrash(second, fromPreview: secondID)
        // Another file takes the first one's name meanwhile.
        try Fixtures.write(named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 30), in: h.folder)

        await h.model.putBack(first, fromPreview: firstID)
        #expect(h.model.previews.visible.first { $0.id == firstID }?.failure == .undo, "said on that preview")
        #expect(h.model.actionNote == nil, "not in the popover")
        #expect(h.alerts == 1)
        #expect(h.model.undoables.map(\.file) == [second], "only its Undo ended")
        #expect(h.model.previews.visible.first { $0.id == secondID }?.trashed == true)
        await h.model.putBack(second, fromPreview: secondID)
        #expect(RT.exists(second.url))
    }

    @Test func aFailedTrashFromThePopoverIsSaidThere() async throws {
        let h = try ModelHarness(hasTrash: false)
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.recent.first?.url == url })
        await h.model.ledgerSettled()
        let file = try #require(h.model.recent.first)

        await h.model.moveToTrash(file)
        #expect(RT.exists(url))
        #expect(h.model.actionNote?.failure == .trash(.noTrash))
        #expect(h.alerts == 1, "the alert sound plays as well, not instead")
        #expect(h.announced.last == Copy.Failure.noTrash.key)
    }

    @Test func aFailedTrashFromThePreviewIsSaidOnThePreview() async throws {
        let h = try ModelHarness(hasTrash: false)
        defer { h.tearDown() }
        #expect(await h.start())
        let (file, id) = try await shotWithPreview(h)
        await h.model.moveToTrash(file, fromPreview: id)
        #expect(h.model.previews.visible.first { $0.id == id }?.failure == .trash(.noTrash))
        #expect(h.model.actionNote == nil, "said where the user acted, not in the popover")
        #expect(h.alerts == 1)
    }

    @Test func aFailedUndoIsSaidAndTheNoteLeavesOnItsOwn() async throws {
        let h = try ModelHarness(undoLifetime: .milliseconds(300))
        defer { h.tearDown() }
        #expect(await h.start())
        await h.model.putBack()
        #expect(h.model.actionNote?.failure == .undo)
        #expect(h.alerts == 1)
        #expect(h.announced.last == Copy.Failure.undoFailed.key)
        #expect(await eventually { await h.model.actionNote == nil })
    }

    /// Minor 3: a Copy from a row (its pill, its menu, VoiceOver, all `copyAgain(file:)`) that
    /// fails says why in the note above the list, with the alert sound and VoiceOver.
    @Test func aFailedCopyFromARowIsSaid() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.recent.count == 1 })
        let row = try #require(h.model.recent.first)
        // Gone in Finder while the popover is open.
        let away = try Fixtures.makeDir().appendingPathComponent("Screenshot 1.png")
        try FileManager.default.moveItem(at: url, to: away)

        #expect(await !h.model.copyAgain(file: row))
        #expect(h.model.actionNote?.failure == .copy)
        #expect(h.alerts == 1)
        #expect(h.announced.last == Copy.Failure.copyFailed.key)

        // The clipboard refusing is said the same way.
        try FileManager.default.moveItem(at: away, to: url)
        h.pasteboard.failing = true
        #expect(await !h.model.copyAgain(file: row))
        #expect(h.alerts == 2)
        #expect(h.model.actionNote?.failure == .copy)
    }

    /// The same on a floating preview (its hover button, its menu, VoiceOver): said on the
    /// preview itself, and gone once a Copy from it works.
    @Test func aFailedCopyFromAPreviewIsSaidOnIt() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (file, id) = try await shotWithPreview(h)
        let actions = PreviewFileActions.model(h.model)

        h.pasteboard.failing = true
        #expect(await !actions.copy(file, id))
        #expect(h.model.previews.visible.first { $0.id == id }?.failure == .copy)
        #expect(h.model.actionNote == nil, "said where the user acted, not in the popover")
        #expect(h.alerts == 1)
        #expect(h.announced.last == Copy.Failure.copyFailed.key)

        h.pasteboard.failing = false
        #expect(await actions.copy(file, id))
        #expect(h.model.previews.visible.first { $0.id == id }?.failure == nil)
    }

    @Test(arguments: [
        (ScreenshotActionFailure.copy, Copy.Failure.copyFailed.key),
        (.trash(.notTracked), Copy.Failure.notTracked.key),
        (.trash(.outsideFolder), Copy.Failure.outsideFolder.key),
        (.trash(.noTrash), Copy.Failure.noTrash.key),
        (.trash(.failed), Copy.Failure.trashFailed.key),
        (.undo, Copy.Failure.undoFailed.key),
    ])
    func everyFailureHasItsOwnWords(failure: ScreenshotActionFailure, key: String) {
        #expect(failure.message.key == key)
    }
}

/// R-2: one clipboard write path. Every write ClipShot makes counts, animates the menu bar
/// and is announced; paused stops only what ClipShot does on its own.
@MainActor
struct ClipboardPathTests {
    @Test func everyKindOfCopyCountsAnimatesAndIsAnnounced() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.preferences.totals.copied == 1 })
        let file = try #require(h.model.lastCopied)
        #expect(h.announced.filter { $0 == Copy.screenshotCopied.key }.count == 1)

        #expect(await h.model.copyAgain(file: file))
        #expect(h.preferences.totals.copied == 2, "Copy again counts as a copy")
        #expect(h.model.flashPhase > 0)

        #expect(h.model.writeClipboard(Fixtures.pngImage(size: 21), .edited))
        #expect(h.preferences.totals.copied == 3, "an edited copy counts as a copy")
        #expect(h.announced.filter { $0 == Copy.screenshotCopied.key }.count == 3)
        #expect(h.pasteboard.writes.count == 3)
    }

    @Test func pausedStopsOnlyWhatClipShotDoesOnItsOwn() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.preferences.totals.copied == 1 })
        let file = try #require(h.model.lastCopied)
        h.preferences.copyEnabled = false

        #expect(!h.model.writeClipboard(Fixtures.pngImage(size: 22), .edited), "an edited copy waits for copying")
        #expect(await h.model.copyAgain(file: file), "an explicit Copy works while paused")
        #expect(h.preferences.totals.copied == 2)
        #expect(h.pasteboard.writes.count == 2)
    }
}
