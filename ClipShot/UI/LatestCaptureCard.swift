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

    private static let checkDuration: Duration = .milliseconds(1_200)

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

            // A translation can make the two buttons wider than the card; then they stack, at
            // the same full width, rather than truncate. The symbols stay: Copy again shows
            // its checkmark there.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Design.Spacing.s) { actions(stacked: false) }
                VStack(alignment: .leading, spacing: Design.Spacing.s) { actions(stacked: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
    }

    /// Side by side at their own width with Move to Trash at the trailing end, or stacked at
    /// the full card width with the labels leading and Move to Trash beside Show in Finder.
    @ViewBuilder
    private func actions(stacked: Bool) -> some View {
        Button { copyAgain() } label: {
            Label {
                // Copy again for the screenshot just copied; Copy for one shown in its place.
                Text(capture.isLastCopied ? Copy.Action.copyAgain : Copy.Preview.copy)
            } icon: {
                Image(systemName: showCheck ? "checkmark" : "doc.on.doc")
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            }
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
        }
        .fixedSize(horizontal: !stacked, vertical: true)
        if stacked {
            HStack(spacing: Design.Spacing.s) {
                revealButton(stacked: true)
                trashButton
            }
        } else {
            revealButton(stacked: false)
            Spacer(minLength: 0)
            trashButton
        }
    }

    private func revealButton(stacked: Bool) -> some View {
        Button { model.reveal(capture.file) } label: {
            Label { Text(Copy.Action.showInFinder) } icon: { Image(systemName: "folder") }
                .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
        }
        .fixedSize(horizontal: !stacked, vertical: true)
    }

    /// Move to Trash, with no confirmation: the Undo row above puts it back for 5 s.
    private var trashButton: some View {
        Button { trash() } label: {
            Image(systemName: "trash")
        }
        .fixedSize()
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
