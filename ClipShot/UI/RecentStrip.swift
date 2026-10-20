import AppKit
import SwiftUI

/// The previous screenshots under the latest card (spec Addendum A5): up to four thumbnails,
/// newest first, hidden when there are none. A click opens Markup and a drag carries the file
/// into another app. On hover or keyboard focus each one shows the latest card's actions as
/// round buttons, as the floating preview does: Copy, Show in Finder and Move to Trash. A
/// right click offers Copy, Edit with Markup, Show in Finder and Move to Trash, as on the
/// floating preview; VoiceOver has the same as named actions.
///
/// Motion (A3): the screenshot the card hands down slides in from the leading edge while the
/// others make room; one that leaves shrinks and drops, and its neighbours close the gap with
/// a spring. Reduce Motion keeps crossfades only.
struct RecentStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let leave = AnyTransition.scale(scale: 0.4, anchor: .bottom)
            .combined(with: .offset(y: 10))
            .combined(with: .opacity)
            .animation(Design.Motion.stripLeave)
        return .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: leave)
    }

    @Environment(\.hoveredRecent) private var hoveredRecent

    var body: some View {
        StripLayout(columns: RecentScreenshots.count) {
            ForEach(Array(model.recent.enumerated()), id: \.element) { index, file in
                RecentItem(file: file, image: model.thumbnails[file], hovering: index == hoveredRecent)
                    .transition(transition)
            }
        }
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.strip, value: model.recent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.Recent.strip))
    }
}

/// Equal columns across the whole width: the first item starts at the leading edge and the
/// last column ends at the trailing edge, in line with the card above. Items keep their
/// column when there are fewer of them. No items, no height.
struct StripLayout: Layout {
    let columns: Int

    private func itemSize(_ subviews: Subviews) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let item = itemSize(subviews)
        let minimum = item.width * CGFloat(columns) + Design.Spacing.s * CGFloat(columns - 1)
        return CGSize(width: max(proposal.width ?? minimum, minimum), height: item.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let item = itemSize(subviews)
        let step = columns > 1 ? (bounds.width - item.width) / CGFloat(columns - 1) : 0
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + step * CGFloat(index), y: bounds.minY),
                proposal: ProposedViewSize(item))
        }
    }
}

/// One earlier screenshot: the picture, and on hover or keyboard focus a pencil (a click
/// opens Markup) and the bar of actions.
struct RecentItem: View {
    let file: CaptureFile
    let image: CGImage?

    /// Where keyboard focus is: the thumbnail or one of its buttons. The bar stays while it
    /// is anywhere in here, so Tab can reach its buttons.
    enum Focus: Hashable {
        case thumbnail, copy, reveal, trash
    }

    /// Space and Return open Markup only from the thumbnail itself: on one of its buttons
    /// they press that button.
    static func keyOpensMarkup(focus: Focus?) -> Bool {
        focus == .thumbnail
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering: Bool
    @FocusState private var focus: Focus?
    @State private var showCheck = false
    @State private var checkTask: Task<Void, Never>?

    /// `hovering` is for the render harness, which draws the hover state.
    init(file: CaptureFile, image: CGImage?, hovering: Bool = false) {
        self.file = file
        self.image = image
        _hovering = State(initialValue: hovering)
    }

    private var showsActions: Bool { hovering || focus != nil }

    /// The shade behind the bar: the buttons and a little above them.
    private static let scrimHeight: CGFloat = 30

    var body: some View {
        ZStack {
            CaptureThumbnail(image: image)
            CardInteraction(
                file: file, image: image,
                onClick: markup,
                onHover: { hovering = $0 },
                onDraggedOut: {},
                menu: menuItems)
                .accessibilityHidden(true)
            if showsActions {
                HoverScrim(height: Self.scrimHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .transition(.opacity)
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                actionBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 2)
                    .transition(.opacity)
            }
        }
        .frame(width: Design.Layout.thumbnailSize.width, height: Design.Layout.thumbnailSize.height)
        .focusable()
        .focused($focus, equals: .thumbnail)
        .focusEffectDisabled()
        .overlay {
            if focus == .thumbnail {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            guard Self.keyOpensMarkup(focus: focus) else { return .ignored }
            markup()
            return .handled
        }
        .onDisappear { checkTask?.cancel() }
        .animation(Design.Motion.quick, value: showsActions)
        .help(Text(verbatim: file.url.lastPathComponent))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Copy.Recent.item(age: file.created.formatted(.relative(presentation: .named)))))
        .accessibilityHint(Text(Copy.Preview.markupHint))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction { markup() }
        .accessibilityAction(named: Text(Copy.Preview.copy)) { copy() }
        .accessibilityAction(named: Text(Copy.Preview.editWithMarkup)) { markup() }
        .accessibilityAction(named: Text(Copy.Action.showInFinder)) { model.reveal(file) }
        .accessibilityAction(named: Text(Copy.Retention.moveToTrash)) { trash() }
    }

    /// The latest card's three actions, as the floating preview's round buttons.
    private var actionBar: some View {
        HStack(spacing: 1) {
            CardButton(
                symbol: showCheck ? "checkmark" : "doc.on.doc", label: Copy.Preview.copy,
                diameter: CardButton.compactDiameter, action: copy)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .focused($focus, equals: .copy)
            CardButton(
                symbol: "folder", label: Copy.Action.showInFinder,
                diameter: CardButton.compactDiameter, action: { model.reveal(file) })
                .focused($focus, equals: .reveal)
            CardButton(
                symbol: "trash", label: Copy.Retention.moveToTrash,
                diameter: CardButton.compactDiameter, action: trash)
                .focused($focus, equals: .trash)
        }
    }

    private func menuItems() -> [CardMenuItem] {
        [
            CardMenuItem(title: Copy.Preview.copy, action: copy),
            CardMenuItem(title: Copy.Preview.editWithMarkup, action: markup),
            CardMenuItem(title: Copy.Action.showInFinder, action: { model.reveal(file) }),
            CardMenuItem(title: Copy.Retention.moveToTrash, action: trash, separatorBefore: true),
        ]
    }

    private func markup() { model.markup(file) }

    /// The same copy as the latest card's: this screenshot's PNG, the menu bar animation, and
    /// the checkmark on the button for a moment.
    private func copy() {
        checkTask?.cancel()
        checkTask = Task {
            let copied = await model.copyAgain(file: file)
            guard !Task.isCancelled else { return }
            guard copied else {
                withAnimation(Design.Motion.quick) { showCheck = false }
                return
            }
            withAnimation(Design.Motion.quick) { showCheck = true }
            try? await Task.sleep(for: LatestCaptureCard.checkDuration)
            guard !Task.isCancelled else { return }
            withAnimation(Design.Motion.quick) { showCheck = false }
        }
    }

    private func trash() {
        Task {
            do { try await model.trash(file) } catch { NSSound.beep() }
        }
    }
}

/// For 5 seconds after a move to the Trash, from the card, the strip or the floating
/// preview: Undo puts the file back (A6). A second move replaces it; the trash can bounces
/// to say so. It drops in from just above and fades out; Reduce Motion only fades.
struct UndoRow: View {
    let trashed: AppModel.TrashedScreenshot

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The button under the sentence when a translation makes it too wide beside it.
        TrailingActionLayout(hasIcon: true, iconSpacing: Design.Spacing.m) {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? nil : trashed.inTrash)
                .frame(width: Design.Layout.iconColumn)
                .accessibilityHidden(true)
            Text(Copy.Recent.moved)
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { if await !model.undoTrash() { NSSound.beep() } }
            } label: {
                Text(Copy.Recent.undo)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .keyboardShortcut("z")
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.s)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .accessibilityElement(children: .contain)
    }

    /// Drops in from just above; leaves by fading, faster.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -Design.Motion.undoDrop).combined(with: .opacity).animation(Design.Motion.undoIn),
            removal: .opacity.animation(Design.Motion.leave))
    }
}
