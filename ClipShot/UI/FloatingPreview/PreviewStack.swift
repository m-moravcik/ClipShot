import AppKit
import SwiftUI

/// The floating previews, stacked: the newest at the bottom, older ones above it.
///
/// Motion (Addendum A3, designed with motion-polish), each with its job:
/// - arrival: springs in from the screen edge with a small overshoot (where the copy went);
/// - the image lands with a slight scale-up and the Copied badge bounces (the copy happened);
/// - older previews slide up with a spring when a new one arrives (connects the states);
/// - leaving: on time it slides back to the edge, Close shrinks away, Move to Trash shrinks
///   and drops; neighbours close the gap with the stack spring.
/// Reduce Motion: every one of these is a crossfade.
struct PreviewStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: PreviewCardMetrics.spacing) {
            ForEach(model.previews.items) { item in
                PreviewCard(item: item, actions: actions(for: item))
                    .transition(transition(for: item))
            }
        }
        // The panel ends at the visible frame's edges: the cards sit the macOS inset from
        // them, with room above and to the left for the shadow and the hover buttons.
        .padding([.top, .leading], PreviewCardMetrics.margin)
        .padding([.bottom, .trailing], PreviewCardMetrics.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        // Reduce Motion: no layout movement; the cards' own crossfades carry the change.
        .animation(reduceMotion ? nil : Design.Motion.stack, value: model.previews.items.map(\.id))
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

    private func actions(for item: PreviewItem) -> PreviewActions {
        let previews = model.previews
        let file = item.file
        let id = item.id
        return PreviewActions(
            markup: { [model] in
                model.markup(file)
                previews.dismiss(id, .close)
            },
            copy: { [model] in Task { await model.copyAgain(file: file) } },
            reveal: { [model] in model.reveal(file) },
            trash: { [model] in
                Task {
                    do { try await model.trash(file) } catch { NSSound.beep() }
                }
            },
            close: { previews.dismiss(id, .close) },
            swipedAway: { previews.dismiss(id, .swipe) },
            draggedOut: { previews.dismiss(id, .close) },
            hover: { previews.setHovering(id, $0) },
            clipboardChanged: { [model] in model.clipboardChangedSinceCopy })
    }
}
