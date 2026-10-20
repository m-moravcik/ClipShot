import AppKit
import SwiftUI
import Testing
@testable import ClipShot

/// The popover's bottom edge: in the app the footer is the scroll view's bottom bar, so rows
/// scrolling under it soften into the edge; the render harness (`offscreenCapture`), which
/// draws such a bar black, keeps the footer below the scroll view.
@MainActor
struct PopoverLayoutTests {
    /// The popover laid out in a window, as AppKit installs scroll edge effects only there.
    private func layout(_ model: AppModel, offscreenCapture: Bool) async throws -> (pockets: [NSView], height: CGFloat) {
        let root = MenuContent()
            .environment(model)
            .environment(SettingsRouter())
            .environment(UpdateStatus())
            .environment(\.offscreenCapture, offscreenCapture)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: Design.Layout.popoverWidth, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
        }
        hosting.layoutSubtreeIfNeeded()
        // The scroll pockets are AppKit's private views behind `.scrollEdgeEffectStyle`.
        var pockets: [NSView] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)) == "NSScrollPocket" { pockets.append(view) }
            view.subviews.forEach(walk)
        }
        walk(hosting)
        return (pockets, hosting.fittingSize.height)
    }

    /// The pockets at the bottom edge of their scroll view.
    private func bottom(_ pockets: [NSView]) -> [NSView] {
        pockets.filter { pocket in
            guard let scroll = pocket.superview else { return false }
            let frame = scroll.convert(pocket.frame, to: nil)
            let bounds = scroll.convert(scroll.bounds, to: nil)
            // Window coordinates: y grows upwards, so the bottom edge is minY.
            return abs(frame.minY - bounds.minY) < 0.5 && frame.height > 0
        }
    }

    @Test func appHasABottomSoftEdgeAndTheHarnessDoesNot() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.latest != nil })

        let app = try await layout(h.model, offscreenCapture: false)
        let harness = try await layout(h.model, offscreenCapture: true)
        #expect(app.pockets.count == 2, "top and bottom")
        #expect(bottom(app.pockets).count == 1)
        #expect(harness.pockets.count == 1, "top only")
        #expect(bottom(harness.pockets).isEmpty)
        // The bottom bar adds no height and covers no row: both layouts are equally tall.
        #expect(app.height == harness.height)
    }
}
