import AppKit
import SwiftUI

/// The window the floating previews live in: non-activating, on every Space, over full-screen
/// apps, at the bottom right of the screen the capture came from (Addendum A2).
///
/// One transparent panel holds the whole stack, sized for three previews and reaching the
/// visible frame's right and bottom edges, so a swipe slides out past the edge and the
/// arrival comes in from it. Its transparent parts let clicks through to the windows below.
@MainActor
final class PreviewPanelController {
    /// Room for three of the largest previews, their spacing and the margins.
    static var panelSize: CGSize {
        let card = PreviewCardMetrics.maxSize
        let count = CGFloat(FloatingPreviews.maxVisible)
        return CGSize(
            width: card.width + PreviewCardMetrics.margin + PreviewCardMetrics.screenInset,
            height: card.height * count + PreviewCardMetrics.spacing * (count - 1)
                + PreviewCardMetrics.margin + PreviewCardMetrics.screenInset)
    }

    /// After the last preview left: long enough for its exit to finish before the panel goes.
    private static let hideDelay: Duration = .milliseconds(450)

    /// Weak: the model owns this controller.
    private weak var model: AppModel?
    private var panel: PreviewPanel?
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        model.previews.onChange = { [weak self] in self?.update() }
    }

    private func update() {
        guard let model else { return }
        guard let newest = model.previews.visible.last else {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hideDelay)
                guard !Task.isCancelled, let self, self.model?.previews.items.isEmpty ?? true else { return }
                self.panel?.orderOut(nil)
            }
            return
        }
        hideTask?.cancel()
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        if let screen = CaptureScreen.screen(for: newest.file.url) {
            let visible = screen.visibleFrame
            let size = Self.panelSize
            panel.setFrame(
                NSRect(x: visible.maxX - size.width, y: visible.minY, width: size.width, height: size.height),
                display: false)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ model: AppModel) -> PreviewPanel {
        let panel = PreviewPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        let hosting = FirstMouseHostingView(rootView: PreviewRoot(model: WeakModelBox(model)))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }
}

/// Never takes focus from the app the user is in: a click on a button does not make it key,
/// so the frontmost app keeps its keyboard focus.
final class PreviewPanel: NSPanel {
    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
    }

    // Key only when VoiceOver or the keyboard asks for it (`becomesKeyOnlyIfNeeded`).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A click on a preview acts at once, even though ClipShot is not the active app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Buttons and gestures need no keyboard focus, so a click leaves it with the user's app.
    override var needsPanelToBecomeKey: Bool { false }
}

/// The model, held weakly, so the panel's view does not keep it alive.
@MainActor
private final class WeakModelBox {
    weak var value: AppModel?

    init(_ value: AppModel) {
        self.value = value
    }
}

private struct PreviewRoot: View {
    let model: WeakModelBox

    var body: some View {
        if let model = model.value {
            PreviewStack().environment(model)
        }
    }
}
