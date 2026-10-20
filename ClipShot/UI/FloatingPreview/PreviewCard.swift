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

    /// Past this share of its width, letting go dismisses the preview whatever the speed.
    static let dismissFraction: CGFloat = 0.4

    /// The swipe has gone far enough that letting go now dismisses the preview: the card
    /// says so before the release (a tilt, a fade, a trackpad tick).
    static func pastDismissPoint(_ translation: CGFloat, width: CGFloat) -> Bool {
        translation > width * dismissFraction
    }

    /// The card tips, fades a little and ticks: past the dismiss point, and only while the
    /// swipe is held. After the release a fling moves the card on its own, without them.
    static func showsCommit(swiping: Bool, translation: CGFloat, width: CGFloat) -> Bool {
        swiping && pastDismissPoint(translation, width: width)
    }

    /// A release that should fling the preview away rather than spring it back.
    static func flings(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        pastDismissPoint(translation, width: width) || (velocity > 450 && translation > 8)
    }
}

/// What a preview's buttons, menu and gestures do. Built by `PreviewStack` from the model.
struct PreviewActions {
    var markup: () -> Void
    /// Copy again; true once the screenshot is on the clipboard.
    var copy: () async -> Bool
    var reveal: () -> Void
    var trash: () -> Void
    /// Undo on a preview that moved its screenshot to the Trash.
    var undo: () -> Void
    var close: () -> Void
    var swipedAway: () -> Void
    var draggedOut: () -> Void
    var hover: (Bool) -> Void
    /// Whether hover offers Copy again: this preview's screenshot is not the one on the
    /// clipboard (the same owner the Copied badge follows).
    var offersCopyAgain: () -> Bool
}

extension PreviewActions {
    /// Does nothing: for the render harness.
    static var inert: PreviewActions {
        PreviewActions(
            markup: {}, copy: { false }, reveal: {}, trash: {}, undo: {}, close: {}, swipedAway: {}, draggedOut: {},
            hover: { _ in }, offersCopyAgain: { true })
    }
}

/// One floating preview: the screenshot, a Copied badge (only while it is the screenshot on
/// the clipboard), "+N" for more displays, and on hover the Markup pencil,
/// Close, Copy again and Move to Trash. Click opens Markup, a drag carries the file out, a
/// swipe towards the screen edge dismisses it. Moved to the Trash from here, it turns into
/// "Moved to the Trash" with Undo while the Undo lasts; a failed action says why on it.
struct PreviewCard: View {
    let item: PreviewItem
    let actions: PreviewActions
    /// This screenshot is the one on the clipboard now.
    var showsCopied = true
    /// The image's scale, fixed; for the render harness's key frames.
    private let imageScale: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering: Bool
    @State private var offerCopy: Bool
    @State private var dragX: CGFloat = 0
    /// A swipe is held: the pointer is down and moving the card.
    @State private var swiping = false
    @State private var landed = false
    @State private var badgeBounce = 0
    /// The wait before the badge's next bounce, or a Copy again; cancelled when the card goes.
    @State private var bounceTask: Task<Void, Never>?
    /// The screenshot is being dragged into another app: the card ghosts while it is in hand.
    @State private var inHand = false

    /// `hovering`, `imageScale` and `dragX` exist for the render harness, which draws the
    /// hover state and animation key frames.
    init(
        item: PreviewItem, actions: PreviewActions, showsCopied: Bool = true, hovering: Bool = false,
        imageScale: CGFloat? = nil, dragX: CGFloat = 0
    ) {
        self.item = item
        self.actions = actions
        self.showsCopied = showsCopied
        self.imageScale = imageScale
        _hovering = State(initialValue: hovering)
        _offerCopy = State(initialValue: hovering)
        _dragX = State(initialValue: dragX)
        _swiping = State(initialValue: dragX > 0)
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
            // Hover lifts the picture and its overlays towards the pointer; the pointer
            // handling stays put, so its tracking area never moves under the pointer.
            picture
                .offset(y: lift)
                .animation(Design.Motion.hover, value: hovering)
            CardInteraction(
                overhang: PreviewCardMetrics.hoverOverhang,
                file: item.file, image: item.image,
                toolTip: String(localized: Copy.Preview.markupHint),
                onClick: actions.markup,
                onHover: hoverChanged,
                onSwipeChanged: {
                    swiping = true
                    dragX = PreviewCardMetrics.rubberBand($0)
                },
                onSwipeEnded: swipeEnded,
                onDragBegan: { inHand = true },
                onDragEnded: { _ in inHand = false },
                onDraggedOut: actions.draggedOut,
                menu: menuItems)
                .padding(-PreviewCardMetrics.hoverOverhang)
                .accessibilityHidden(true)
            overlays
                .offset(y: lift)
                .animation(Design.Motion.hover, value: hovering)
        }
        .frame(width: size.width, height: size.height)
        // While the swipe is held past the point where letting go dismisses it, the card tips
        // and fades a little, and comes back if the pointer does; a Force Touch trackpad ticks
        // as it crosses. Not after the release: a fling never tips or ticks. Animated on its
        // own value, inside the swipe's offset, so the swipe keeps following the pointer.
        .rotationEffect(.degrees(pastDismissPoint && !reduceMotion ? Design.Motion.swipeCommitAngle : 0),
                        anchor: .bottomLeading)
        .opacity(pastDismissPoint ? Design.Motion.swipeCommitOpacity : 1)
        .animation(Design.Motion.swipeCommit, value: pastDismissPoint)
        .offset(x: dragX)
        .opacity(reduceMotion && dragX > 0 ? Double(max(0.3, 1 - dragX / size.width)) : 1)
        .opacity(inHand ? Design.Motion.dragGhostOpacity : 1)
        .animation(Design.Motion.quick, value: inHand)
        .onChange(of: pastDismissPoint) { _, past in
            if past { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.Preview.accessibility))
        .accessibilityHint(Text(Copy.Preview.markupHint))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction { actions.markup() }
        .accessibilityAction(named: Text(Copy.Preview.copy)) { copy() }
        .accessibilityAction(named: Text(Copy.Preview.editWithMarkup)) { actions.markup() }
        .accessibilityAction(named: Text(Copy.Action.showInFinder)) { actions.reveal() }
        .accessibilityAction(named: Text(Copy.Retention.moveToTrash)) { actions.trash() }
        .accessibilityAction(named: Text(Copy.Preview.close)) { actions.close() }
        .onAppear(perform: arrived)
        .onDisappear {
            bounceTask?.cancel()
            bounceTask = nil
        }
    }

    /// Only while the swipe is held: after the release, a fling moves `dragX` on its own.
    private var pastDismissPoint: Bool {
        PreviewCardMetrics.showsCommit(swiping: swiping, translation: dragX, width: size.width)
    }

    /// Hover lifts the card; nothing changes with Reduce Motion.
    private var lifted: Bool { hovering && !reduceMotion }
    private var lift: CGFloat { lifted ? -Design.Motion.hoverLift : 0 }

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
        // Hover: the card lifts (see `card`) and its shadow spreads. Reduce Motion: neither.
        .shadow(color: .black.opacity(0.28), radius: lifted ? 14 : 10, y: lifted ? 6 : 4)
        .animation(Design.Motion.hover, value: hovering)
    }

    private var overlays: some View {
        ZStack {
            // Under the badge and the buttons: it shades the picture, not them.
            if hovering {
                HoverScrim(height: 44)
                    .clipShape(shape)
                    .transition(.opacity)
            }
            // Only the screenshot on the clipboard says Copied; another fades it out, and its
            // hover offers Copy again. A failed action says why in the same place.
            if let failure = item.failure {
                FailureBadge(failure: failure)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .transition(.opacity)
            } else {
                CopiedBadge(bounce: badgeBounce)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .opacity(showsCopied ? 1 : 0)
                    .animation(Design.Motion.quick, value: showsCopied)
            }
            // Pops in when the capture turns out to cover more displays (it can, after the
            // preview arrived), and counts up in place.
            if item.extraDisplays > 0 {
                ExtraDisplaysChip(count: item.extraDisplays)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
            }
            if hovering {
                // The picture is the Markup button, as in the popover's list.
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
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.chip, value: item.extraDisplays)
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
        bounceBadge()
    }

    /// The badge bounces as Peg's clamp bites in the menu bar. Reduce Motion: no bounce.
    private func bounceBadge() {
        guard !reduceMotion else { return }
        bounceTask?.cancel()
        bounceTask = Task {
            do { try await Task.sleep(for: Design.Motion.badgeDelay) } catch { return }
            badgeBounce += 1
        }
    }

    /// Copy again, from the hover button, the menu or VoiceOver: once the screenshot is on the
    /// clipboard, the Copied badge bounces again, in step with the menu bar.
    private func copy() {
        bounceTask?.cancel()
        bounceTask = Task {
            let copied = await actions.copy()
            guard !Task.isCancelled else { return }
            // A Copy that failed (the card says why) can be tried again from the same hover.
            if !copied, hovering { offerCopy = true }
            guard copied, !reduceMotion else { return }
            do { try await Task.sleep(for: Design.Motion.badgeDelay) } catch { return }
            badgeBounce += 1
        }
    }

    private func hoverChanged(_ inside: Bool) {
        if inside { offerCopy = actions.offersCopyAgain() }
        hovering = inside
        actions.hover(inside)
    }

    private func copyAgain() {
        copy()
        offerCopy = false
    }

    private func swipeEnded(translation: CGFloat, velocity: CGFloat) {
        swiping = false
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
            CardMenuItem(title: Copy.Preview.copy, action: { copy() }),
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
struct TrashedPreview: View {
    let failure: ScreenshotActionFailure?
    let undo: () -> Void
    /// The words; nil is the failure's message, or "Moved to the Trash". Tests measure others.
    var text: LocalizedStringResource?

    private var icon: some View {
        Image(systemName: failure == nil ? "trash" : "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .accessibilityHidden(true)
    }

    var body: some View {
        // Undo beside the words, or under them when a translation makes it too wide. Tight
        // spacing, so "Moved to the Trash" stays on one line in English.
        TrailingActionLayout(hasIcon: true, iconSpacing: Design.Spacing.s + 2, spacing: Design.Spacing.s + 2) {
            icon
            Text(text ?? failure?.message ?? Copy.Recent.moved)
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
        .padding(.horizontal, 8)
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
            .contentTransition(.numericText(value: Double(count)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.regularMaterial))
            .accessibilityLabel(Text(Copy.Preview.extraDisplays(count)))
    }
}
