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

    @Test func previewLeavesAfterItsLifetimeUnlessHovered() async throws {
        let previews = FloatingPreviews(lifetime: .milliseconds(300))
        let shots = try files(2)
        previews.show(shots[0], image: nil)
        previews.show(shots[1], image: nil)
        let hovered = try #require(previews.visible.last)
        previews.setHovering(hovered.id, true)
        try await Task.sleep(for: .milliseconds(700))
        #expect(previews.visible.map(\.file) == [shots[1]], "the other one timed out")
        previews.setHovering(hovered.id, false)
        // Stays at least `afterHover` once the pointer leaves.
        try await Task.sleep(for: .milliseconds(500))
        #expect(previews.visible.count == 1)
        #expect(await eventually(timeout: .seconds(3)) { await previews.items.isEmpty })
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

    @Test func copyAgainIsOfferedOnlyAfterTheClipboardChanged() async throws {
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
