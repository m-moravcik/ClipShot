import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClipShot

@MainActor
struct FloatingPreviewsTests {
    private func files(_ count: Int) throws -> [CaptureFile] {
        let dir = try Fixtures.makeDir()
        return try (0..<count).map { index in
            try #require(CaptureFile.inspect(try Fixtures.write(named: "Shot \(index).png", in: dir)))
        }
    }

    @Test func stackKeepsThreeAndTheOldestLeavesFirst() async throws {
        let previews = FloatingPreviews()
        let shots = try files(4)
        for shot in shots { previews.show(shot, image: nil) }
        #expect(previews.visible.map(\.file) == Array(shots.suffix(3)), "newest last, at the bottom")
        #expect(previews.items.first?.exit == .timeout, "the oldest is leaving")
        #expect(await eventually { await previews.items.count == 3 })
        // The same file again is not shown twice.
        previews.show(shots[3], image: nil)
        #expect(previews.visible.count == 3)
    }

    /// U9: "Copied" follows the clipboard. Only the screenshot ClipShot last copied says it;
    /// after its Move to Trash no other preview claims it; Copy again on an older preview
    /// moves it there; another app's copy takes it away.
    @Test func copiedFollowsTheClipboard() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .clipShot })
        let previews = h.model.previews
        func copied() -> [String] { previews.visible.filter(previews.showsCopied).map(\.file.url.lastPathComponent) }

        try h.shoot("A.png", size: 20)
        #expect(await eventually { await previews.visible.count == 1 })
        try h.shoot("B.png", size: 21)
        #expect(await eventually { await previews.visible.count == 2 })
        #expect(copied() == ["B.png"], "the newest copy only")

        let b = try #require(previews.visible.last)
        await h.model.ledgerSettled()
        await h.model.moveToTrash(b.file, fromPreview: b.id)
        #expect(copied().isEmpty, "A was not copied again: it does not claim the clipboard")

        let a = try #require(previews.visible.first)
        #expect(await h.model.copyAgain(file: a.file))
        #expect(copied() == ["A.png"], "Copy again moves Copied to A")

        h.pasteboard.changeCount += 1
        h.model.forgetClipboardIfReplaced()
        #expect(copied().isEmpty, "another app's copy: nothing says Copied")
    }

    /// On a manual clock: nothing leaves a moment before its time, so the checks that a
    /// preview is still there are facts, not races with the real clock.
    @Test func previewLeavesAfterItsLifetimeUnlessHovered() async throws {
        let clock = ManualTimerClock()
        let previews = FloatingPreviews(lifetime: .seconds(5), clock: clock)
        let shots = try files(2)
        previews.show(shots[0], image: nil)
        previews.show(shots[1], image: nil)
        let hovered = try #require(previews.visible.last)

        clock.advance(by: .milliseconds(4_500))
        previews.setHovering(hovered.id, true)
        clock.advance(by: .milliseconds(499))
        #expect(previews.visible.count == 2, "a moment before its 5 s, the other one is still there")
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await previews.visible.map { $0.file } == [shots[1]] }, "the other one timed out")

        // Hovered with 0.5 s left: once the pointer leaves it stays `afterHover` (1.5 s).
        clock.advance(by: .seconds(60))
        #expect(previews.visible.count == 1, "no clock runs while the pointer is over it")
        previews.setHovering(hovered.id, false)
        clock.advance(by: FloatingPreviews.afterHover - .milliseconds(1))
        #expect(previews.visible.count == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await previews.visible.isEmpty })
        #expect(await eventually { await previews.items.isEmpty })
    }

    /// I1: hover offers Copy again on the preview whose screenshot is not the one on the
    /// clipboard, from the same owner as the Copied badge and the popover's rows.
    @Test func hoverOffersCopyAgainWhereTheScreenshotIsNotOnTheClipboard() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .clipShot })
        let previews = h.model.previews
        let stack = PreviewStack(previews: previews, files: .model(h.model))
        func offers(_ name: String) throws -> Bool {
            let item = try #require(previews.visible.first { $0.file.url.lastPathComponent == name })
            return stack.actions(for: item).offersCopyAgain()
        }

        try h.shoot("A.png", size: 20)
        #expect(await eventually { await previews.visible.count == 1 })
        try h.shoot("B.png", size: 21)
        #expect(await eventually { await previews.visible.count == 2 })
        #expect(try offers("A.png"), "B is on the clipboard: the older preview offers Copy again")
        #expect(try !offers("B.png"), "the clipboard's own screenshot does not")

        // Copy on A's row in the popover: now B's preview offers it, A's does not.
        #expect(await eventually { await h.model.recent.count == 2 })
        let rowA = try #require(h.model.recent.first { $0.url.lastPathComponent == "A.png" })
        #expect(await h.model.copyAgain(file: rowA))
        #expect(try !offers("A.png"))
        #expect(try offers("B.png"))
        #expect(h.model.isOnClipboard(rowA), "the row and the preview agree")

        // Another app copies something: seen at once on hover, so both offer it.
        h.pasteboard.changeCount += 1
        #expect(try offers("A.png"))
        #expect(try offers("B.png"))
        #expect(previews.clipboardFile == nil)
    }

    /// A card drawn hovered (the README picture, the motion sheet) never shows the Copied
    /// badge and Copy again together, a state the app cannot reach.
    @Test func aHoveredCardNeverShowsCopiedAndCopyAgainTogether() {
        #expect(!PreviewCard.offersCopyAgain(hovering: true, showsCopied: true))
        #expect(PreviewCard.offersCopyAgain(hovering: true, showsCopied: false))
        #expect(!PreviewCard.offersCopyAgain(hovering: false, showsCopied: false))
        #expect(!PreviewCard.offersCopyAgain(hovering: false, showsCopied: true))
    }

    /// Minor 2: rows and previews compare owners one way: by the file's resource ID, so two
    /// spellings of one path agree; by the standardized path only when there is no ID.
    @Test func theOwnerIsTheSameFileWhateverItsPathSpelling() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Shot.png", in: dir)
        let path = url.path
        let other = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        let a = try #require(CaptureFile.inspect(url))
        let b = try #require(CaptureFile.inspect(URL(fileURLWithPath: other)))
        #expect(a.url.path != b.url.path)

        let previews = FloatingPreviews()
        previews.clipboardFile = a
        #expect(previews.isOnClipboard(b), "/var and /private/var name the same file")
        previews.show(b, image: nil)
        let item = try #require(previews.visible.first)
        #expect(previews.showsCopied(item))
        #expect(!previews.offersCopyAgain(item.id))

        // Without an ID, the standardized path decides.
        func noID(_ path: String) -> CaptureFile {
            CaptureFile(url: URL(fileURLWithPath: path), created: a.created, modified: a.modified, size: a.size,
                        resourceID: Data(), isScreenshot: true)
        }
        #expect(FloatingPreviews.sameFile(noID("/tmp/x/./y/../Shot.png"), noID("/tmp/x/Shot.png")))
        #expect(!FloatingPreviews.sameFile(noID("/tmp/x/Shot.png"), noID("/tmp/x/Other.png")))
        // A file replaced under the same name is another file.
        let replaced = CaptureFile(url: a.url, created: a.created, modified: a.modified, size: a.size,
                                   resourceID: Data([1, 2, 3]), isScreenshot: true)
        #expect(!FloatingPreviews.sameFile(a, replaced))
    }

    @Test func dismissMarksTheExitThenRemoves() async throws {
        let previews = FloatingPreviews()
        let shot = try #require(try files(1).first)
        var changes = 0
        previews.onChange = { changes += 1 }
        previews.show(shot, image: nil)
        let item = try #require(previews.visible.first)
        previews.dismiss(item.id, .trash)
        #expect(previews.items.first?.exit == .trash, "the view draws the exit before removal")
        #expect(previews.visible.isEmpty)
        #expect(await eventually { await previews.items.isEmpty })
        #expect(changes == 2)
    }

    @Test func multiDisplayShowsOnePreviewWithExtraCount() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        #expect(await h.start())
        let main = CoordinatorHarness.png(60)
        try Fixtures.write(named: "Screenshot 1.png", contents: main, in: h.folder, kind: "display")
        try await Task.sleep(for: .milliseconds(10))
        try Fixtures.write(named: "Screenshot 1 (2).png", contents: CoordinatorHarness.png(61), in: h.folder, kind: "display")
        #expect(await eventually { await h.model.previews.visible.first?.extraDisplays == 1 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(h.model.previews.visible.count == 1)
        #expect(h.model.previews.visible.first?.file.url.lastPathComponent == "Screenshot 1.png")
        #expect(h.pasteboard.writes == [main])
    }

    @Test func markupOpensTheFileInAnEditSession() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        h.markupResult = .openedInPreview
        h.model.markup(file)
        #expect(h.markups == [url])
        #expect(h.edits.isEditing(file), "Preview never says when it closes: the session stays")
    }

    @Test func markupCopyIsCopiedAndTheOriginalLeftAlone() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let original = Fixtures.pngImage(size: 30)
        let url = try Fixtures.write(named: "Screenshot 1.png", contents: original, in: h.folder)
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        let file = try #require(CaptureFile.inspect(url))
        let edited = Fixtures.pngImage(size: 31)
        h.markupResult = .savedCopy(edited)
        h.model.markup(file)
        #expect(await eventually { await h.pasteboard.writes.last == edited })
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func editedCopyIsNotWrittenWhilePaused() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        h.preferences.copyEnabled = false
        h.markupResult = .savedCopy(Fixtures.pngImage(size: 33))
        h.model.markup(try #require(CaptureFile.inspect(url)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.pasteboard.writes.count == 1, "paused: nothing written on ClipShot's own")
    }

    @Test func anotherAppsCopyIsSeenByTheChangeCount() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        #expect(!h.model.clipboardChangedSinceCopy)
        h.pasteboard.changeCount += 1
        #expect(h.model.clipboardChangedSinceCopy, "another app copied something")
    }

    /// The model owns the panel controller, which owns the panel: the panel's view must not
    /// hold the model, or the model could never be released while the panel exists.
    @Test func previewPanelViewDoesNotKeepTheModelAlive() async throws {
        let ref = WeakModel()
        var hosting: NSView?
        do {
            let h = try ModelHarness()
            let shot = try #require(try files(1).first)
            h.model.previews.show(shot, image: nil)
            let view = NSHostingView(rootView: PreviewPanelController.content(for: h.model))
            view.frame = CGRect(origin: .zero, size: PreviewPanelController.panelSize)
            view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.height > 0)
            hosting = view
            ref.value = h.model
        }
        for _ in 0..<50 where ref.value != nil { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(ref.value == nil, "the panel's view keeps no model alive")
        withExtendedLifetime(hosting) {}
    }

    /// A dragged screenshot's PNG provider stays registered while the receiving app may ask
    /// for the data, and no longer: when the pasteboard is done with it, or shortly after the
    /// drag ended when the pasteboard never says so.
    @Test func dragImageProvidersDoNotOutliveTheirDrag() async throws {
        let shot = try #require(try files(1).first)
        let before = DragImageProvider.liveCount

        let finished = DragImageProvider.start(for: shot.url)
        #expect(DragImageProvider.liveCount == before + 1)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        finished.pasteboardFinishedWithDataProvider(board)
        #expect(DragImageProvider.liveCount == before)

        // The pasteboard never reports it is done: the end of the drag bounds it.
        let abandoned = DragImageProvider.start(for: shot.url)
        #expect(DragImageProvider.liveCount == before + 1)
        abandoned.dragEnded(linger: .milliseconds(100))
        #expect(DragImageProvider.liveCount == before + 1, "the drop may still read it")
        #expect(await eventually { DragImageProvider.liveCount == before })
        #expect(DragImageProvider.lingerAfterDrag <= .seconds(60))
    }
}
