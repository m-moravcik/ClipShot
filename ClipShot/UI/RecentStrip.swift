import AppKit
import SwiftUI

/// The previous screenshots under the latest card (spec Addendum A5): up to four thumbnails,
/// newest first, hidden when there are none. A click opens Markup, a drag carries the file
/// into another app, and hover (a "more" button) or a right click offers Copy, Edit with
/// Markup, Show in Finder and Move to Trash, as on the floating preview.
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

    var body: some View {
        StripLayout(columns: RecentScreenshots.count) {
            ForEach(model.recent, id: \.self) { file in
                RecentItem(file: file, image: model.thumbnails[file])
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

/// One earlier screenshot: the picture, a pencil and a "more" button on hover.
private struct RecentItem: View {
    let file: CaptureFile
    let image: CGImage?

    @Environment(AppModel.self) private var model
    @State private var hovering = false

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
            if hovering {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                moreButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(3)
                    .transition(.opacity)
            }
        }
        .frame(width: Design.Layout.thumbnailSize.width, height: Design.Layout.thumbnailSize.height)
        .animation(Design.Motion.quick, value: hovering)
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

    private var moreButton: some View {
        Menu {
            Button { copy() } label: { Text(Copy.Preview.copy) }
            Button { markup() } label: { Text(Copy.Preview.editWithMarkup) }
            Button { model.reveal(file) } label: { Text(Copy.Action.showInFinder) }
            Divider()
            Button { trash() } label: { Text(Copy.Retention.moveToTrash) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(Copy.Recent.moreActions))
        .accessibilityLabel(Text(Copy.Recent.moreActions))
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

    private func copy() {
        Task { await model.copyAgain(file: file) }
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
