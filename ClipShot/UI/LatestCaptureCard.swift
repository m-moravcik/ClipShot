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

    /// The age in words, as a sentence starts: "41 minutes ago", "2 hours ago", "Yesterday".
    static func relativeAge(_ created: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(for: created, relativeTo: max(now, created))
    }

    static func == (a: LatestCapture, b: LatestCapture) -> Bool {
        a.file == b.file && a.thumbnail === b.thumbnail && a.isLastCopied == b.isLastCopied
    }
}

enum Thumbnailer {
    /// A downscaled image, decoded now rather than at first draw. Synchronous file IO. Read
    /// through `FileTrust`, like a copy: nil for a file it refuses (only screenshots owned
    /// by this user ever reach the card, the strip or the preview, so that is a file that
    /// changed hands since).
    nonisolated static func decode(_ url: URL, maxPixelSize: Int, policy: FileTrust.Policy = .standard) -> CGImage? {
        guard case .success(let data) = FileTrust.read(url, policy: policy),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              FileTrust.allowsPixels(of: source, policy: policy)
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
/// ones (A5), with the Undo row on top for 5 s after a move to the Trash (A6), and in its
/// place why a Move to Trash or an Undo from here did not happen. Swaps cards with a
/// crossfade only once the new thumbnail is decoded, so it never flashes empty.
struct LatestCaptureSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Design.Spacing.m) {
            if let note = model.actionNote {
                ActionNoteRow(message: note.failure.message)
                    .id(note.generation)
                    .transition(UndoRow.transition(reduceMotion: reduceMotion))
            }
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
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.strip, value: model.actionNote)
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
    @Environment(\.locale) private var locale
    @Environment(\.hoveredCardPill) private var hoveredPill
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
                CardThumbnail(file: capture.file, image: capture.thumbnail, menu: menuItems)
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

            // Compact pills at their own width, leading, as VibeRes's profile pills: Copy again
            // with its title, Show in Finder and Move to Trash as symbols, so the row fits one
            // line in every language. A longer one (pseudo-de) wraps rather than truncating.
            FlowLayout(spacing: Design.Spacing.s, lineSpacing: Design.Spacing.s) {
                copyButton.environment(\.pillHovered, hoveredPill == 0)
                revealButton.environment(\.pillHovered, hoveredPill == 1)
                trashButton.environment(\.pillHovered, hoveredPill == 2)
            }
            .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .onDisappear { checkTask?.cancel() }
    }

    /// The picture's right-click menu: the strip's, so both offer the same.
    private func menuItems() -> [CardMenuItem] {
        [
            CardMenuItem(title: capture.isLastCopied ? Copy.Action.copyAgain : Copy.Preview.copy, action: copyAgain),
            CardMenuItem(title: Copy.Preview.editWithMarkup, action: { model.markup(capture.file) }),
            CardMenuItem(title: Copy.Action.showInFinder, action: { model.reveal(capture.file) }),
            CardMenuItem(title: Copy.Retention.moveToTrash, action: trash, separatorBefore: true),
        ]
    }

    /// Copy again for the screenshot just copied; Copy for one shown in its place. The symbol
    /// turns into a checkmark for a moment after a copy.
    private var copyButton: some View {
        Button { copyAgain() } label: {
            PillLabel(
                symbol: showCheck ? "checkmark" : "doc.on.doc",
                title: capture.isLastCopied ? Copy.Action.copyAgain : Copy.Preview.copy)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        }
        .help(Text(capture.isLastCopied ? Copy.Action.copyAgain : Copy.Preview.copy))
    }

    private var revealButton: some View {
        Button { model.reveal(capture.file) } label: {
            PillLabel(symbol: "folder")
        }
        .help(Text(Copy.Action.showInFinder))
        .accessibilityLabel(Text(Copy.Action.showInFinder))
    }

    /// Move to Trash, with no confirmation: the Undo row above puts it back for 5 s.
    private var trashButton: some View {
        Button { trash() } label: {
            PillLabel(symbol: "trash")
        }
        .help(Text(Copy.Retention.moveToTrash))
        .accessibilityLabel(Text(Copy.Retention.moveToTrash))
    }

    private func trash() {
        let file = capture.file
        Task { await model.moveToTrash(file) }
    }

    /// "Just now" for the first minute, then the age in words ("41 minutes ago", "Yesterday"),
    /// refreshed once a minute.
    private var age: some View {
        let created = capture.file.created
        return TimelineView(AgeSchedule(switchAt: created.addingTimeInterval(LatestCapture.justNowInterval))) { context in
            if LatestCapture.isJustNow(created, now: context.date) {
                Text(Copy.Latest.justNow)
            } else {
                Text(verbatim: LatestCapture.relativeAge(created, now: context.date, locale: locale))
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

/// The card's picture, as the strip's and the preview's: a click opens Markup, a drag
/// carries the file into another app, a right click offers the menu. A pencil on hover or
/// keyboard focus says the picture is the thing to click; Space or Return opens Markup.
private struct CardThumbnail: View {
    let file: CaptureFile
    let image: CGImage?
    let menu: () -> [CardMenuItem]

    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            CaptureThumbnail(image: image)
            CardInteraction(
                file: file, image: image, toolTip: String(localized: Copy.Preview.markupHint),
                onClick: { model.markup(file) }, onHover: { hovering = $0 }, onDraggedOut: {}, menu: menu)
            if hovering || focused {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: Design.Layout.thumbnailSize.width, height: Design.Layout.thumbnailSize.height)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(keys: [.space, .return]) { _ in
            model.markup(file)
            return .handled
        }
        .animation(Design.Motion.quick, value: hovering)
    }
}

/// Why something the user asked for in the popover did not happen: a Move to Trash or an
/// Undo (in the Undo row's place, for 5 s, with the alert sound as well), or a macOS setting
/// ClipShot could not change.
struct ActionNoteRow: View {
    let message: LocalizedStringResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .frame(width: Design.Layout.iconColumn)
                .accessibilityHidden(true)
            Text(message)
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.s + 2)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .accessibilityElement(children: .combine)
    }
}

/// The card's age: the moment "Just now" ends, then once a minute.
struct AgeSchedule: TimelineSchedule {
    let switchAt: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = current < switchAt ? switchAt : current.addingTimeInterval(60)
            return current
        }
    }
}
