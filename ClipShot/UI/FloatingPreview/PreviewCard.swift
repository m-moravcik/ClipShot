import AppKit
import SwiftUI

/// Sizes of the floating preview, close to the macOS thumbnail (spike: a 400x300 pt
/// selection gave a 188x125 pt thumbnail, 12 pt from the screen's right and bottom edges).
enum PreviewCardMetrics {
    static let maxSize = CGSize(width: 200, height: 140)
    /// Wide enough for the Copied badge in every language.
    static let minWidth: CGFloat = 132
    static let minHeight: CGFloat = 64
    /// Decoded at twice the largest side, for Retina.
    static let imagePixels = 400
    static let radius: CGFloat = 10
    static let spacing: CGFloat = 10
    /// From the visible frame's right and bottom edges, as the macOS thumbnail sits.
    static let screenInset: CGFloat = 12
    /// Room around the stack for the shadow and the hover buttons that overhang the card.
    static let margin: CGFloat = 18
    /// How far the Close button reaches past the card's corner, as on the macOS thumbnail.
    static let closeOverhang: CGFloat = 7
    /// Hover is tracked this far past the card, so the overhanging Close button keeps it.
    static let hoverOverhang: CGFloat = 10

    /// The card for an image of `pixels`: aspect-fit into `maxSize`, never smaller than the
    /// minimum (a very thin capture is shown cropped to fill).
    static func size(for image: CGImage?) -> CGSize {
        guard let image, image.width > 0, image.height > 0 else { return CGSize(width: 168, height: 108) }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        var width = maxSize.width
        var height = width / aspect
        if height > maxSize.height {
            height = maxSize.height
            width = height * aspect
        }
        return CGSize(width: max(minWidth, width.rounded()), height: max(minHeight, height.rounded()))
    }

    /// Leftward drags resist and stop after about 40 pt; rightward drags follow the pointer.
    static func rubberBand(_ translation: CGFloat) -> CGFloat {
        guard translation < 0 else { return translation }
        let limit: CGFloat = 40
        return -limit * (1 - 1 / (-translation / 120 + 1))
    }

    /// A release that should fling the preview away rather than spring it back.
    static func flings(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        translation > width * 0.4 || (velocity > 450 && translation > 8)
    }
}

/// What a preview's buttons, menu and gestures do. Built by `PreviewStack` from the model.
struct PreviewActions {
    var markup: () -> Void
    var copy: () -> Void
    var reveal: () -> Void
    var trash: () -> Void
    /// Undo on a preview that moved its screenshot to the Trash.
    var undo: () -> Void
    var close: () -> Void
    var swipedAway: () -> Void
    var draggedOut: () -> Void
    var hover: (Bool) -> Void
    /// Whether the clipboard holds something else now, so Copy again is worth offering.
    var clipboardChanged: () -> Bool
}

extension PreviewActions {
    /// Does nothing: for the render harness.
    static var inert: PreviewActions {
        PreviewActions(
            markup: {}, copy: {}, reveal: {}, trash: {}, undo: {}, close: {}, swipedAway: {}, draggedOut: {},
            hover: { _ in }, clipboardChanged: { true })
    }
}

/// One floating preview: the screenshot, a Copied badge (on the newest only: older ones are
/// no longer on the clipboard), "+N" for more displays, and on hover the Markup pencil,
/// Close, Copy again and Move to Trash. Click opens Markup, a drag carries the file out, a
/// swipe towards the screen edge dismisses it. Moved to the Trash from here, it turns into
/// "Moved to the Trash" with Undo while the Undo lasts; a failed action says why on it.
struct PreviewCard: View {
    let item: PreviewItem
    let actions: PreviewActions
    /// The newest screenshot on show: its copy is the one on the clipboard.
    var isNewest = true
    /// The image's scale, fixed; for the render harness's key frames.
    private let imageScale: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering: Bool
    @State private var offerCopy: Bool
    @State private var dragX: CGFloat = 0
    @State private var landed = false
    @State private var badgeBounce = 0

    /// `hovering` and `imageScale` exist for the render harness, which draws the hover state
    /// and animation key frames.
    init(
        item: PreviewItem, actions: PreviewActions, isNewest: Bool = true, hovering: Bool = false,
        imageScale: CGFloat? = nil
    ) {
        self.item = item
        self.actions = actions
        self.isNewest = isNewest
        self.imageScale = imageScale
        _hovering = State(initialValue: hovering)
        _offerCopy = State(initialValue: hovering)
    }

    /// The image starts this much smaller and lands into the card.
    static let arrivalImageScale: CGFloat = 0.9

    private var size: CGSize { PreviewCardMetrics.size(for: item.image) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PreviewCardMetrics.radius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if item.trashed {
                TrashedPreview(failure: item.failure, undo: actions.undo)
                    .transition(.opacity)
            } else {
                card
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.quick, value: item.trashed)
    }

    private var card: some View {
        ZStack {
            picture
            CardInteraction(
                overhang: PreviewCardMetrics.hoverOverhang,
                file: item.file, image: item.image,
                toolTip: String(localized: Copy.Preview.markupHint),
                onClick: actions.markup,
                onHover: hoverChanged,
                onSwipeChanged: { dragX = PreviewCardMetrics.rubberBand($0) },
                onSwipeEnded: swipeEnded,
                onDraggedOut: actions.draggedOut,
                menu: menuItems)
                .padding(-PreviewCardMetrics.hoverOverhang)
                .accessibilityHidden(true)
            overlays
        }
        .frame(width: size.width, height: size.height)
        .offset(x: dragX)
        .opacity(reduceMotion && dragX > 0 ? Double(max(0.3, 1 - dragX / size.width)) : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.Preview.accessibility))
        .accessibilityHint(Text(Copy.Preview.markupHint))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction { actions.markup() }
        .accessibilityAction(named: Text(Copy.Preview.copy)) { actions.copy() }
        .accessibilityAction(named: Text(Copy.Preview.editWithMarkup)) { actions.markup() }
        .accessibilityAction(named: Text(Copy.Action.showInFinder)) { actions.reveal() }
        .accessibilityAction(named: Text(Copy.Retention.moveToTrash)) { actions.trash() }
        .accessibilityAction(named: Text(Copy.Preview.close)) { actions.close() }
        .onAppear(perform: arrived)
    }

    private var picture: some View {
        ZStack {
            if let image = item.image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(imageScale ?? (landed || reduceMotion ? 1 : Self.arrivalImageScale))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: size.width, height: size.height)
                    .background(.regularMaterial)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    private var overlays: some View {
        ZStack {
            // Under the badge and the buttons: it shades the picture, not them.
            if hovering {
                HoverScrim(height: 44)
                    .clipShape(shape)
                    .transition(.opacity)
            }
            // Only the newest says Copied; an older one fades it out, and its hover offers
            // Copy again. A failed action says why in the same place.
            if let failure = item.failure {
                FailureBadge(failure: failure)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .transition(.opacity)
            } else {
                CopiedBadge(bounce: badgeBounce)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .opacity(isNewest ? 1 : 0)
                    .animation(Design.Motion.quick, value: isNewest)
            }
            if item.extraDisplays > 0 {
                ExtraDisplaysChip(count: item.extraDisplays)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
            if hovering {
                // The picture is the Markup button, as on the card and the strip.
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                hoverButtons
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.quick, value: hovering)
        .animation(Design.Motion.quick, value: item.failure)
    }

    private var hoverButtons: some View {
        ZStack {
            CardButton(symbol: "xmark", label: Copy.Preview.close, action: actions.close)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .offset(x: -PreviewCardMetrics.closeOverhang, y: -PreviewCardMetrics.closeOverhang)
            HStack(spacing: 4) {
                if offerCopy {
                    CardButton(symbol: "doc.on.doc", label: Copy.Action.copyAgain, action: copyAgain)
                }
                CardButton(symbol: "trash", label: Copy.Retention.moveToTrash, action: actions.trash)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(6)
        }
    }

    private func arrived() {
        guard !reduceMotion else {
            landed = true
            return
        }
        withAnimation(Design.Motion.land) { landed = true }
        Task {
            try? await Task.sleep(for: Design.Motion.badgeDelay)
            badgeBounce += 1
        }
    }

    private func hoverChanged(_ inside: Bool) {
        if inside { offerCopy = actions.clipboardChanged() }
        hovering = inside
        actions.hover(inside)
    }

    private func copyAgain() {
        actions.copy()
        offerCopy = false
    }

    private func swipeEnded(translation: CGFloat, velocity: CGFloat) {
        let current = PreviewCardMetrics.rubberBand(translation)
        guard PreviewCardMetrics.flings(translation: current, velocity: velocity, width: size.width) else {
            withAnimation(reduceMotion ? Design.Motion.quick : Design.Motion.snapBack) { dragX = 0 }
            return
        }
        if reduceMotion {
            actions.swipedAway()
            return
        }
        // Out past the screen edge, at the speed of the release.
        let target = size.width + PreviewCardMetrics.screenInset + PreviewCardMetrics.margin
        withAnimation(Design.Motion.fling(velocity: velocity, distance: target - current)) { dragX = target }
        Task {
            try? await Task.sleep(for: Design.Motion.flingHandOff)
            actions.swipedAway()
        }
    }

    private func menuItems() -> [CardMenuItem] {
        [
            CardMenuItem(title: Copy.Preview.copy, action: actions.copy),
            CardMenuItem(title: Copy.Preview.editWithMarkup, action: actions.markup),
            CardMenuItem(title: Copy.Action.showInFinder, action: actions.reveal),
            CardMenuItem(title: Copy.Retention.moveToTrash, action: actions.trash, separatorBefore: true),
            CardMenuItem(title: Copy.Preview.close, action: actions.close),
        ]
    }
}

/// "Copied": the reason the preview is there. It bounces once as it lands, in step with the
/// menu bar flash; Reduce Motion keeps it still.
private struct CopiedBadge: View {
    let bounce: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
            Text(Copy.Preview.copied)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.regularMaterial))
        .accessibilityHidden(true)
    }
}

/// Why an action on this preview did not happen, in place of the Copied badge.
private struct FailureBadge: View {
    let failure: ScreenshotActionFailure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure.message)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
        .accessibilityElement(children: .combine)
    }
}

/// A preview whose screenshot it moved to the Trash: "Moved to the Trash" and Undo, at the
/// spot the preview was, while the Undo lasts (Addendum A6). Undo puts it back without
/// opening the popover.
private struct TrashedPreview: View {
    let failure: ScreenshotActionFailure?
    let undo: () -> Void

    private var icon: some View {
        Image(systemName: failure == nil ? "trash" : "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .accessibilityHidden(true)
    }

    var body: some View {
        // Undo beside the words, or under them when a translation makes it too wide.
        TrailingActionLayout(hasIcon: true, iconSpacing: Design.Spacing.m) {
            icon
            Text(failure?.message ?? Copy.Recent.moved)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if failure == nil {
                Button(action: undo) { Text(Copy.Recent.undo) }
                    .buttonStyle(PillButtonStyle())
                    .fixedSize()
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: PreviewCardMetrics.maxSize.width)
        .background(
            RoundedRectangle(cornerRadius: PreviewCardMetrics.radius, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: PreviewCardMetrics.radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}

/// "+1" when the capture covered more displays than the preview shows.
private struct ExtraDisplaysChip: View {
    let count: Int

    var body: some View {
        Text(verbatim: "+\(count.formatted())")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.regularMaterial))
            .accessibilityLabel(Text(Copy.Preview.extraDisplays(count)))
    }
}
