import AppKit
import SwiftUI

/// The floating previews, stacked: the newest at the bottom, older ones above it.
///
/// Motion (Addendum A3), each with its job:
/// - arrival: springs in from the screen edge with a small overshoot (where the copy went);
/// - the image lands with a slight scale-up and the Copied badge bounces (the copy happened);
/// - older previews slide up with a spring when a new one arrives (connects the states);
/// - leaving: on time it slides back to the edge, Close shrinks away, Move to Trash shrinks
///   and drops; neighbours close the gap with the stack spring.
/// Reduce Motion: every one of these is a crossfade.
///
/// It gets the previews and what a preview does to its screenshot, not the model: the model
/// owns the panel this view lives in, so holding the model here would keep it alive.
struct PreviewStack: View {
    let previews: FloatingPreviews
    let files: PreviewFileActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: PreviewCardMetrics.spacing) {
            ForEach(previews.items) { item in
                PreviewCard(item: item, actions: actions(for: item), showsCopied: previews.showsCopied(item))
                    .transition(transition(for: item))
            }
        }
        // The panel ends at the visible frame's edges: the cards sit the macOS inset from
        // them, with room above and to the left for the shadow and the hover buttons.
        .padding([.top, .leading], PreviewCardMetrics.margin)
        .padding([.bottom, .trailing], PreviewCardMetrics.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Reduce Motion: no layout movement; the cards' own crossfades carry the change.
        .animation(reduceMotion ? nil : Design.Motion.stack, value: previews.items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.Preview.panel))
    }

    private func transition(for item: PreviewItem) -> AnyTransition {
        if reduceMotion { return AnyTransition.opacity.animation(Design.Motion.quick) }
        let arrive = AnyTransition.move(edge: .trailing).animation(Design.Motion.arrive)
        let leave: AnyTransition
        switch item.exit {
        case .trash?:
            leave = AnyTransition.scale(scale: 0.35, anchor: .bottom)
                .combined(with: .offset(y: 36))
                .combined(with: .opacity)
                .animation(Design.Motion.drop)
        case .close?:
            leave = AnyTransition.scale(scale: 0.85).combined(with: .opacity).animation(Design.Motion.leave)
        case .swipe?:
            leave = AnyTransition.opacity.animation(Design.Motion.leave)
        case .timeout?, nil:
            leave = AnyTransition.move(edge: .trailing).combined(with: .opacity).animation(Design.Motion.leave)
        }
        return .asymmetric(insertion: arrive, removal: leave)
    }

    /// Internal for the tests, which hover a preview through it.
    func actions(for item: PreviewItem) -> PreviewActions {
        let previews = previews
        let files = files
        let file = item.file
        let id = item.id
        return PreviewActions(
            markup: {
                files.markup(file)
                previews.dismiss(id, .close)
            },
            copy: { await files.copy(file, id) },
            reveal: { files.reveal(file) },
            trash: { files.trash(file, id) },
            undo: { files.undo(file, id) },
            close: { previews.dismiss(id, .close) },
            swipedAway: { previews.dismiss(id, .swipe) },
            draggedOut: { previews.dismiss(id, .close) },
            hover: { previews.setHovering(id, $0) },
            offersCopyAgain: {
                // Another app's copy is noticed at once, not at the next status tick.
                files.forgetClipboardIfReplaced()
                return previews.offersCopyAgain(id)
            })
    }
}

/// What a floating preview does to its screenshot, through the model, which it holds weakly:
/// once the model is gone, they do nothing.
@MainActor
struct PreviewFileActions {
    let markup: @MainActor (CaptureFile) -> Void
    /// Copies the file again; true once it is on the clipboard. A failure is said on the
    /// preview with that id.
    let copy: @MainActor (CaptureFile, UUID) async -> Bool
    let reveal: @MainActor (CaptureFile) -> Void
    /// Moves the file to the Trash; the preview with that id then offers Undo, or says why not.
    let trash: @MainActor (CaptureFile, UUID) -> Void
    /// Puts back the file that preview moved, and only that one.
    let undo: @MainActor (CaptureFile, UUID) -> Void
    /// Lets go of the clipboard's owner when another app copied something since.
    let forgetClipboardIfReplaced: @MainActor () -> Void

    static func model(_ model: AppModel) -> PreviewFileActions {
        PreviewFileActions(
            markup: { [weak model] in model?.markup($0) },
            copy: { [weak model] file, id in
                guard let model else { return false }
                return await model.copyAgain(file: file, fromPreview: id)
            },
            reveal: { [weak model] in model?.reveal($0) },
            trash: { [weak model] file, id in
                guard let model else { return }
                Task { await model.moveToTrash(file, fromPreview: id) }
            },
            undo: { [weak model] file, id in
                guard let model else { return }
                Task { await model.putBack(file, fromPreview: id) }
            },
            forgetClipboardIfReplaced: { [weak model] in model?.forgetClipboardIfReplaced() })
    }
}
