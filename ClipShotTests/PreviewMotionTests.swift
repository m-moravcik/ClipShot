import AppKit
import Foundation
import Testing
@testable import ClipShot

/// The floating preview's motion logic: where a swipe commits, the lifted drag image, and
/// Copy again reporting back so the badge can bounce.
@MainActor
struct PreviewMotionTests {
    /// The card tips and ticks exactly where letting go starts to dismiss it, whatever the
    /// release speed: the feedback never promises what the release does not do.
    @Test func swipeCommitsWhereTheReleaseDismisses() {
        let width: CGFloat = 200
        #expect(!PreviewCardMetrics.pastDismissPoint(width * 0.39, width: width))
        #expect(PreviewCardMetrics.pastDismissPoint(width * 0.41, width: width))
        for translation in stride(from: CGFloat(0), through: width, by: 5)
        where PreviewCardMetrics.pastDismissPoint(translation, width: width) {
            #expect(PreviewCardMetrics.flings(translation: translation, velocity: 0, width: width),
                    "past the point at \(translation) pt, a slow release still dismisses")
        }
        #expect(!PreviewCardMetrics.pastDismissPoint(PreviewCardMetrics.rubberBand(-500), width: width),
                "a leftward drag never commits")
    }

    /// The tip, fade and tick belong to the held swipe: a fling after the release, which
    /// carries the card far past the point, never shows them.
    @Test func commitFeedbackOnlyWhileTheSwipeIsHeld() {
        let width: CGFloat = 200
        #expect(PreviewCardMetrics.showsCommit(swiping: true, translation: width * 0.5, width: width))
        #expect(!PreviewCardMetrics.showsCommit(swiping: false, translation: width * 0.5, width: width))
        #expect(!PreviewCardMetrics.showsCommit(swiping: false, translation: width * 2, width: width), "a fling")
        #expect(!PreviewCardMetrics.showsCommit(swiping: true, translation: width * 0.3, width: width))
    }

    /// The drag image is the picture a little larger, raised off its card, with room for its
    /// shadow; the drag starts centred on the card so the pointer keeps its place on it.
    @Test func dragImageIsLiftedOffTheCard() throws {
        let image = try #require(Self.image(width: 88, height: 60))
        let card = NSRect(x: 10, y: 20, width: 44, height: 30)
        let lifted = DragLift.lifted(image, frame: card)
        #expect(lifted.image.size == lifted.frame.size)
        #expect(lifted.frame.width > card.width * DragLift.scale)
        #expect(lifted.frame.height > card.height * DragLift.scale)
        #expect(abs(lifted.frame.midX - card.midX) < 0.001)
        #expect(abs(lifted.frame.midY - (card.midY + DragLift.raise)) < 0.001, "raised, y up")
        #expect(lifted.frame.contains(card))
    }

    /// Copy again from a preview reports whether the screenshot reached the clipboard, which
    /// is when its badge bounces again.
    @Test func copyAgainFromAPreviewReportsTheCopy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.lastCopied != nil })
        let file = try #require(h.model.lastCopied)
        let actions = PreviewFileActions.model(h.model)
        #expect(await actions.copy(file))
        #expect(h.preferences.totals.copied == 2)
        h.pasteboard.failing = true
        #expect(await !actions.copy(file))
    }

    private static func image(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
