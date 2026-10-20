import AppKit
import ImageIO
import SwiftUI

/// The latest copied screenshot and its thumbnail, decoded off the main actor.
struct LatestCapture: Identifiable, Equatable, @unchecked Sendable {
    /// Twice the card's 64 pt, for Retina.
    static let thumbnailPixels = 128

    let file: CaptureFile
    /// nil when the file could not be decoded (a PDF, or a file already gone).
    let thumbnail: CGImage?
    /// The screenshot last copied; false for the newest one shown in its place once that is
    /// gone, or before any copy this session. Its button then says Copy, not Copy again.
    var isLastCopied = true

    var id: CaptureFile { file }

    /// Under a minute the card says "Just now" rather than counting seconds.
    static let justNowInterval: TimeInterval = 60

    static func isJustNow(_ created: Date, now: Date) -> Bool {
        now.timeIntervalSince(created) < justNowInterval
    }

    static func == (a: LatestCapture, b: LatestCapture) -> Bool {
        a.file == b.file && a.thumbnail === b.thumbnail && a.isLastCopied == b.isLastCopied
    }
}

enum Thumbnailer {
    /// A downscaled image, decoded now rather than at first draw. Synchronous file IO.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The latest screenshot, or a quiet line before the first one, then the strip of earlier
/// ones (A5), with the Undo row on top for 5 s after a move to the Trash (A6). Swaps cards
/// with a crossfade only once the new thumbnail is decoded, so it never flashes empty.
struct LatestCaptureSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Design.Spacing.m) {
            if let trashed = model.undoable {
                UndoRow(trashed: trashed)
                    .transition(UndoRow.transition(reduceMotion: reduceMotion))
            }
            card
            if !model.recent.isEmpty {
                RecentStrip()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.strip, value: model.undoable != nil)
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.strip, value: model.recent.isEmpty)
    }

    private var card: some View {
        ZStack {
            if let latest = model.latest {
                LatestCaptureCard(capture: latest)
                    .id(latest.id)
                    .transition(.opacity)
            } else {
                Text(Copy.Latest.none)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                    .transition(.opacity)
            }
        }
        // A crossfade, which Reduce Motion keeps.
        .animation(Design.Motion.quick, value: model.latest?.id)
    }
}

struct LatestCaptureCard: View {
    let capture: LatestCapture

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCheck = false
    @State private var checkTask: Task<Void, Never>?

    /// How long a button shows its checkmark after a copy; the strip uses it too.
    static let checkDuration: Duration = .milliseconds(1_200)

    private var size: String {
        capture.file.size.formatted(.byteCount(style: .file))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            HStack(spacing: Design.Spacing.m) {
                MarkupThumbnail(image: capture.thumbnail, file: capture.file)
                VStack(alignment: .leading, spacing: 1) {
                    // Two lines before anything is cut, so the time at the end of a
                    // screenshot's name, which tells screenshots apart, stays whole.
                    Text(verbatim: capture.file.url.lastPathComponent)
                        .font(Design.Typography.cardTitle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text(verbatim: capture.file.url.lastPathComponent))
                    // Age and size on one line, or one under the other when a long "Just
                    // now" leaves no room.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Design.Spacing.s) {
                            age
                            Text(verbatim: "·")
                            Text(verbatim: size)
                        }
                        .fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            age.fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: size)
                        }
                    }
                    .font(Design.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Copy.Latest.accessibility(
                age: capture.file.created.formatted(.relative(presentation: .named)), size: size)))
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: Text(Copy.Preview.editWithMarkup)) { model.markup(capture.file) }
            .accessibilityAction(named: Text(Copy.Retention.moveToTrash)) { trash() }

            // One row in every language: Copy again takes the width the two square icon
            // buttons leave, and all three are as tall as each other.
            CardActionsLayout {
                copyButton
                revealButton
                trashButton
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
    }

    /// Copy again for the screenshot just copied; Copy for one shown in its place. The symbol
    /// turns into a checkmark for a moment after a copy. A label too long for the row wraps
    /// onto a second line before anything is cut.
    private var copyButton: some View {
        Button { copyAgain() } label: {
            Label {
                Text(capture.isLastCopied ? Copy.Action.copyAgain : Copy.Preview.copy)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } icon: {
                Image(systemName: showCheck ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var revealButton: some View {
        Button { model.reveal(capture.file) } label: {
            Image(systemName: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .help(Text(Copy.Action.showInFinder))
        .accessibilityLabel(Text(Copy.Action.showInFinder))
    }

    /// Move to Trash, with no confirmation: the Undo row above puts it back for 5 s.
    private var trashButton: some View {
        Button { trash() } label: {
            Image(systemName: "trash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .help(Text(Copy.Retention.moveToTrash))
        .accessibilityLabel(Text(Copy.Retention.moveToTrash))
    }

    private func trash() {
        let file = capture.file
        Task {
            do { try await model.trash(file) } catch { NSSound.beep() }
        }
    }

    /// "Just now" for the first minute, then the live relative age. The timeline wakes once,
    /// when the minute is up.
    private var age: some View {
        let created = capture.file.created
        let now = Date()
        let switchAt = created.addingTimeInterval(LatestCapture.justNowInterval)
        // The first entry is what renders now; the view gets the entry's date, not the clock.
        return TimelineView(.explicit(switchAt > now ? [now, switchAt] : [now])) { context in
            if LatestCapture.isJustNow(created, now: context.date) {
                Text(Copy.Latest.justNow)
            } else {
                Text(created, style: .relative)
            }
        }
    }

    /// Copies the screenshot this card shows, never another one. A second click restarts the
    /// checkmark's 1.2 s instead of letting the first click's timer cut it short. A click
    /// that fails takes the checkmark away, so an earlier success never stays on show.
    private func copyAgain() {
        let file = capture.file
        checkTask?.cancel()
        checkTask = Task {
            let copied = await model.copyAgain(file: file)
            guard !Task.isCancelled else { return }
            guard copied else {
                withAnimation(Design.Motion.quick) { showCheck = false }
                return
            }
            withAnimation(Design.Motion.quick) { showCheck = true }
            try? await Task.sleep(for: Self.checkDuration)
            guard !Task.isCancelled else { return }
            withAnimation(Design.Motion.quick) { showCheck = false }
        }
    }
}

/// The latest card's buttons, in one row whatever the language: the first (the primary
/// action) takes the width the others leave; the others are square icon buttons. All share
/// one height, so a primary label that has to wrap onto a second line makes the whole row
/// taller rather than stacking it. Frames are worked out left to right; SwiftUI mirrors a
/// custom layout's placement in a right-to-left layout direction, so there the primary sits
/// on the right (`CardActionsLayoutTests.mirrorsRightToLeft`).
struct CardActionsLayout: Layout {
    var spacing: CGFloat = Design.Spacing.s

    /// The frames, primary first, in a row `width` wide. The icon buttons are `side` wide,
    /// and every button is as tall as the taller of `side` and the primary at the width it
    /// gets (`primaryHeight(width)`).
    static func frames(
        width: CGFloat, buttons: Int, side: CGFloat, spacing: CGFloat, primaryHeight: (CGFloat) -> CGFloat
    ) -> [CGRect] {
        guard buttons > 0 else { return [] }
        let secondary = buttons - 1
        let primaryWidth = max(0, width - CGFloat(secondary) * (side + spacing))
        let height = max(side, primaryHeight(primaryWidth))
        var frames = [CGRect(x: 0, y: 0, width: primaryWidth, height: height)]
        for index in 0..<secondary {
            frames.append(CGRect(
                x: primaryWidth + spacing + CGFloat(index) * (side + spacing), y: 0, width: side, height: height))
        }
        return frames
    }

    /// The icon buttons' side: the buttons' one-line height, or an icon button's narrowest
    /// width where its symbol and the bezel's margins need more (a bordered button does not
    /// get narrower than that), so they come out square. `heights` are the buttons' own
    /// heights, `iconMinWidths` the icon buttons' narrowest widths.
    static func side(heights: [CGFloat], iconMinWidths: [CGFloat]) -> CGFloat {
        max(heights.max() ?? 0, iconMinWidths.max() ?? 0)
    }

    private func frames(_ width: CGFloat?, _ subviews: Subviews) -> [CGRect] {
        guard let primary = subviews.first else { return [] }
        // A bordered icon button's own width is a default far wider than its symbol; offered
        // no width, it reports the narrowest it can be.
        let side = Self.side(
            heights: subviews.map { $0.sizeThatFits(.unspecified).height },
            iconMinWidths: subviews.dropFirst().map { $0.sizeThatFits(.zero).width })
        let ideal = primary.sizeThatFits(.unspecified).width + CGFloat(subviews.count - 1) * (side + spacing)
        return Self.frames(
            width: width ?? ideal, buttons: subviews.count, side: side, spacing: spacing,
            primaryHeight: { primary.sizeThatFits(ProposedViewSize(width: $0, height: nil)).height })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(proposal.width, subviews)
        guard let last = frames.last else { return .zero }
        return CGSize(width: last.maxX, height: last.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(bounds.width, subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
