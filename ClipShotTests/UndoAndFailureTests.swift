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
        #expect(h.model.undoable?.file == file, "the popover offers the same Undo")
        #expect(h.model.previews.newestCopiedID != id, "an Undo preview says no Copied")
        #expect(h.announced.contains(Copy.Recent.moved.key))

        await h.model.putBack(file, fromPreview: id)
        #expect(RT.exists(file.url))
        #expect(h.model.undoable == nil)
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
        #expect(await eventually { await h.model.undoable == nil })
        #expect(!h.model.previews.visible.contains { $0.id == id })
    }

    /// One Undo at a time: a newer trash ends an older preview's Undo, and an Undo on that
    /// older preview never brings back the newer screenshot.
    @Test func anOlderPreviewNeverUndoesANewerTrash() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (first, firstID) = try await shotWithPreview(h, "Screenshot 1.png")
        let (second, secondID) = try await shotWithPreview(h, "Screenshot 2.png")
        await h.model.moveToTrash(first, fromPreview: firstID)
        await h.model.moveToTrash(second, fromPreview: secondID)
        #expect(!h.model.previews.visible.contains { $0.id == firstID }, "replaced: the older Undo preview left")
        await h.model.putBack(first, fromPreview: firstID)
        #expect(!RT.exists(second.url), "the newer screenshot stays in the Trash")
        #expect(h.model.undoable?.file == second)
        #expect(h.alerts == 1)
    }

    @Test func aFailedTrashFromThePopoverIsSaidThere() async throws {
        let h = try ModelHarness(hasTrash: false)
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.latest?.file.url == url })
        await h.model.ledgerSettled()
        let file = try #require(h.model.latest?.file)

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

    @Test(arguments: [
        (ScreenshotActionFailure.trash(.notTracked), Copy.Failure.notTracked.key),
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
