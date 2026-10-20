import AppKit
import ImageIO
import SwiftUI

enum Thumbnailer {
    /// A downscaled image, decoded now rather than at first draw. Synchronous file IO. Read
    /// through `FileTrust`, like a copy: nil for a file it refuses (only screenshots owned
    /// by this user ever reach the list or the preview, so that is a file that changed hands
    /// since).
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

/// A screenshot's age as the list says it: "Just now" for the first minute, then in words.
enum ScreenshotAge {
    /// Under a minute a row says "Just now" rather than counting seconds.
    static let justNowInterval: TimeInterval = 60

    static func isJustNow(_ created: Date, now: Date) -> Bool {
        now.timeIntervalSince(created) < justNowInterval
    }

    /// The age in words, as a sentence starts: "41 minutes ago", "2 hours ago", "Yesterday".
    static func relative(_ created: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(for: created, relativeTo: max(now, created))
    }

    /// What a row shows and VoiceOver reads at `now`.
    static func text(_ created: Date, now: Date, locale: Locale) -> String {
        guard !isJustNow(created, now: now) else {
            var justNow = Copy.Latest.justNow
            justNow.locale = locale
            return String(localized: justNow)
        }
        return relative(created, now: now, locale: locale)
    }
}

/// The recent screenshots (Task 12i): why a Move to Trash or an Undo from here did not
/// happen, for 5 s; then the list, or a quiet line before the first screenshot.
struct RecentSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let empty = model.recentSlots.isEmpty
        VStack(spacing: Design.Spacing.m) {
            if let note = model.actionNote {
                ActionNoteRow(message: note.failure.message)
                    .id(note.generation)
                    .transition(ActionNoteRow.transition(reduceMotion: reduceMotion))
            }
            if empty {
                Text(Copy.Latest.none)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                    .transition(.opacity)
            } else {
                RecentList()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.noteMakeRoom, value: model.actionNote)
        .animation(Design.Motion.quick, value: empty)
    }
}

/// The current screenshot and the ones before it, newest first, one row each in one rounded
/// group with hairlines between them, as Eject Guard lists its disks. Every row looks the
/// same: only its place and its age say which one is the current screenshot. While Undo is
/// offered, the screenshot just moved to the Trash keeps its place as a short Undo strip.
///
/// Motion, on `Design.Motion.layout`: a row moved to the Trash shrinks into the Undo strip
/// in one continuous change (same place, so its height animates while the contents
/// crossfade), and Undo grows it back, the screenshot arriving from just smaller as it
/// fades in, so it reads as having come back. Once Undo is over the strip closes, the rows under it
/// move up and the older screenshot fades in on the last row; the rows above never move. A
/// new screenshot fades in on top while the others make room. Reduce Motion: the same
/// crossfades on `quick`.
struct RecentList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hoveredRecent) private var hoveredRecent
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let slots = model.recentSlots
        VStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                Group {
                    switch slot {
                    case .screenshot(let file):
                        RecentRow(
                            file: file, image: model.thumbnails[file], position: index + 1, count: slots.count,
                            onClipboard: model.isOnClipboard(file), hovering: index == hoveredRecent)
                            .transition(RecentRow.transition(reduceMotion: reduceMotion))
                    case .trashed:
                        UndoStrip(inTrash: model.undoable?.inTrash)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if index > 0 {
                        // One device pixel, fainter than a system Divider: on the card's
                        // tint a full Divider reads as a border and splits the group.
                        Rectangle()
                            .fill(Design.Palette.rowSeparator)
                            .frame(height: 1 / displayScale)
                            .padding(.horizontal, Design.Spacing.l)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        .animation(reduceMotion ? Design.Motion.quick : Design.Motion.layout, value: slots)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Copy.Recent.list))
    }
}

/// For 5 seconds after a move to the Trash, from a row or the floating preview, in that
/// screenshot's place in the list: "Moved to the Trash" and Undo (⌘Z), which puts it back
/// there (A6). A second move replaces it; the trash can bounces to say so.
struct UndoStrip: View {
    /// Where the file went; a new one bounces the trash can.
    let inTrash: URL?

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Undo beside the sentence, or under it when a translation makes it too wide there.
        TrailingActionLayout(hasIcon: true, iconSpacing: Design.Spacing.m) {
            // In the thumbnails' column, so the strip lines up with the rows.
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? nil : inTrash)
                .frame(width: RecentRow.thumbnailSize.width)
                .accessibilityHidden(true)
            Text(Copy.Recent.moved)
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.putBack() }
            } label: {
                PillLabel(symbol: "arrow.uturn.backward", title: Copy.Recent.undo)
            }
            .buttonStyle(PillButtonStyle())
            .fixedSize()
            .keyboardShortcut("z")
            .help(Text(Copy.Recent.undo))
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .accessibilityElement(children: .contain)
    }
}

/// One screenshot: its picture (click for Markup, drag it out, right-click for the menu),
/// its name with the time whole, its age and size, and Copy (Copy again while it is the
/// screenshot on the clipboard), Show in Finder and Move to Trash as pills.
struct RecentRow: View {
    /// Twice the 64 pt the tour's Try it draws the same image at, for Retina.
    nonisolated static let thumbnailPixels = 128
    static let thumbnailSize = CGSize(width: 44, height: 30)
    /// The text column of a row in the popover: what the pills have to fit in.
    static let textWidth = Design.Layout.popoverWidth - 2 * Design.Spacing.m - 2 * Design.Spacing.l
        - thumbnailSize.width - Design.Spacing.m

    let file: CaptureFile
    let image: CGImage?
    /// Its place in the list, from 1, and how many rows there are, for VoiceOver.
    let position: Int
    let count: Int
    /// The screenshot ClipShot last put on the clipboard, still there: Copy again.
    let onClipboard: Bool

    /// What can be done to a row's screenshot: VoiceOver's named actions and the picture's
    /// right-click menu, in this order.
    enum Action: CaseIterable {
        case copy, markup, reveal, trash
    }

    /// Copy is Copy again for the screenshot on the clipboard, as its pill.
    static func title(_ action: Action, onClipboard: Bool) -> LocalizedStringResource {
        switch action {
        case .copy: onClipboard ? Copy.Action.copyAgain : Copy.Preview.copy
        case .markup: Copy.Preview.editWithMarkup
        case .reveal: Copy.Action.showInFinder
        case .trash: Copy.Retention.moveToTrash
        }
    }

    /// What VoiceOver reads after the name: "Just now, 1.2 MB, 1 of 4".
    static func accessibilityValue(
        created: Date, size: String, position: Int, count: Int, now: Date, locale: Locale
    ) -> LocalizedStringResource {
        Copy.Recent.rowValue(
            age: ScreenshotAge.text(created, now: now, locale: locale), size: size, position: position, count: count)
    }

    /// Where keyboard focus is in the row: the thumbnail or one of its pills.
    enum Focus: Hashable {
        case thumbnail, copy, reveal, trash
    }

    /// Space and Return open Markup only from the thumbnail itself: on one of the pills they
    /// press that pill.
    static func keyOpensMarkup(focus: Focus?) -> Bool {
        focus == .thumbnail
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.hoveredRecentPill) private var hoveredPill
    @State private var hovering: Bool
    @FocusState private var focus: Focus?
    @State private var showCheck = false
    @State private var checkTask: Task<Void, Never>?
    /// The picture is being dragged into another app: it ghosts while the file is in hand.
    @State private var inHand = false

    /// `hovering` is for the render harness, which draws the thumbnail's hover state.
    init(file: CaptureFile, image: CGImage?, position: Int, count: Int, onClipboard: Bool, hovering: Bool = false) {
        self.file = file
        self.image = image
        self.position = position
        self.count = count
        self.onClipboard = onClipboard
        _hovering = State(initialValue: hovering)
    }

    /// How long Copy shows its checkmark after a copy.
    static let checkDuration: Duration = .milliseconds(1_200)

    /// A row taking the Undo strip's place (Undo put its screenshot back) grows in from just
    /// smaller as it fades in; it leaves into the strip by fading. Reduce Motion: fades.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: Design.Motion.restoredScale).combined(with: .opacity),
            removal: .opacity)
    }

    private var name: String { file.url.lastPathComponent }
    private var size: String { file.size.formatted(.byteCount(style: .file)) }
    private var copyTitle: LocalizedStringResource { Self.title(.copy, onClipboard: onClipboard) }

    /// The age and its VoiceOver value come from one clock: the moment "Just now" ends, then
    /// once a minute.
    var body: some View {
        TimelineView(AgeSchedule(switchAt: file.created.addingTimeInterval(ScreenshotAge.justNowInterval))) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let age = Text(verbatim: ScreenshotAge.text(file.created, now: now, locale: locale))
        return HStack(spacing: Design.Spacing.m) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                FileNameLabel(name: name)
                    .font(Design.Typography.cardTitle)
                    .help(Text(verbatim: name))
                // Age and size on one line, or one under the other when a long "Just now"
                // leaves no room.
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
                // Each pill at its own width, as VibeRes's profile pills; a translation too
                // long for one line (pseudo-de) wraps rather than truncating.
                FlowLayout(spacing: Design.Spacing.s, lineSpacing: Design.Spacing.s) {
                    copyButton.environment(\.pillHovered, isPillHovered(0))
                    revealButton.environment(\.pillHovered, isPillHovered(1))
                    trashButton.environment(\.pillHovered, isPillHovered(2))
                }
                .buttonStyle(PillButtonStyle())
                .padding(.top, Design.Spacing.s + 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .onDisappear { checkTask?.cancel() }
        // One element: the name, then its age, size and place in the list, with the row's
        // actions by name. A click on the element opens Markup, as on the picture.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(Self.accessibilityValue(
            created: file.created, size: size, position: position, count: count, now: now, locale: locale)))
        .accessibilityHint(Text(Copy.Preview.markupHint))
        .accessibilityAction { markup() }
        .accessibilityActions {
            ForEach(Action.allCases, id: \.self) { action in
                Button { perform(action) } label: { Text(Self.title(action, onClipboard: onClipboard)) }
            }
        }
    }

    private func isPillHovered(_ pill: Int) -> Bool {
        hoveredPill == HoveredPill(row: position - 1, pill: pill)
    }

    /// The picture: a click opens Markup and a drag carries the file into another app; a
    /// pencil on hover or keyboard focus says the picture is the thing to click.
    private var thumbnail: some View {
        ZStack {
            CaptureThumbnail(image: image, size: Self.thumbnailSize)
                .opacity(inHand ? Design.Motion.dragGhostOpacity : 1)
                .animation(Design.Motion.quick, value: inHand)
            CardInteraction(
                file: file, image: image, toolTip: String(localized: Copy.Preview.markupHint),
                onClick: markup, onHover: { hovering = $0 },
                onDragBegan: { inHand = true }, onDragEnded: { _ in inHand = false },
                onDraggedOut: {}, menu: menuItems)
                .accessibilityHidden(true)
            if hovering || focus == .thumbnail {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
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
        .animation(Design.Motion.quick, value: hovering)
    }

    /// Copy, or Copy again for the screenshot on the clipboard; the symbol turns into a
    /// checkmark for a moment after a copy.
    private var copyButton: some View {
        Button(action: copy) {
            PillLabel(symbol: showCheck ? "checkmark" : "doc.on.doc", title: copyTitle)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        }
        .help(Text(copyTitle))
        .focused($focus, equals: .copy)
    }

    private var revealButton: some View {
        Button { model.reveal(file) } label: { PillLabel(symbol: "folder") }
            .help(Text(Copy.Action.showInFinder))
            .accessibilityLabel(Text(Copy.Action.showInFinder))
            .focused($focus, equals: .reveal)
    }

    /// Move to Trash, with no confirmation: the Undo strip in its place puts it back for 5 s.
    private var trashButton: some View {
        Button(action: trash) { PillLabel(symbol: "trash") }
            .help(Text(Copy.Retention.moveToTrash))
            .accessibilityLabel(Text(Copy.Retention.moveToTrash))
            .focused($focus, equals: .trash)
    }

    /// The picture's right-click menu: VoiceOver's actions, Move to Trash set apart.
    private func menuItems() -> [CardMenuItem] {
        Action.allCases.map { action in
            CardMenuItem(
                title: Self.title(action, onClipboard: onClipboard), action: { perform(action) },
                separatorBefore: action == .trash)
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .copy: copy()
        case .markup: markup()
        case .reveal: model.reveal(file)
        case .trash: trash()
        }
    }

    private func markup() { model.markup(file) }

    /// Copies this row's screenshot, never another one: its PNG, the menu bar animation, and
    /// the checkmark for a moment. A second click restarts the checkmark's 1.2 s instead of
    /// letting the first click's timer cut it short; a click that fails takes it away.
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
            try? await Task.sleep(for: Self.checkDuration)
            guard !Task.isCancelled else { return }
            withAnimation(Design.Motion.quick) { showCheck = false }
        }
    }

    private func trash() {
        let file = file
        Task { await model.moveToTrash(file) }
    }
}

/// A screenshot's name on one line, cut in the middle when it does not fit, but never in the
/// time at its end: the time is what tells screenshots apart ("Screenshot 2026-10-19 at
/// 09.41.12.png" becomes "Screenshot 2026-1… 09.41.12.png"). A name with no time in it is
/// cut in the middle as usual.
struct FileNameLabel: View {
    let name: String

    /// The name split before its last time of day ("09.41.12", "9:41:12", with whatever
    /// follows it: " AM", " (2)", the extension); the tail starts with the space before it.
    /// nil when the name holds no time.
    struct Parts: Equatable {
        let head: String
        let tail: String
    }

    nonisolated static func split(_ name: String) -> Parts? {
        guard let match = name.matches(of: /\d{1,2}[.:]\d{2}[.:]\d{2}/).last else { return nil }
        var start = match.range.lowerBound
        // The separator before the time goes with the tail, so a cut head ends at its "…".
        if start > name.startIndex {
            let before = name.index(before: start)
            if name[before].isWhitespace { start = before }
        }
        guard start > name.startIndex else { return nil }
        return Parts(head: String(name[..<start]), tail: String(name[start...]))
    }

    var body: some View {
        if let parts = Self.split(name) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: parts.head)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: parts.tail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
        } else {
            Text(verbatim: name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Why something the user asked for in the popover did not happen: a Move to Trash or an
/// Undo (above the list, for 5 s, with the alert sound as well), or a macOS setting ClipShot
/// could not change.
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

    /// Drops in from just above; leaves by fading, faster.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -Design.Motion.noteDrop).combined(with: .opacity).animation(Design.Motion.noteIn),
            removal: .opacity.animation(Design.Motion.leave))
    }
}

/// A row's age: the moment "Just now" ends, then once a minute.
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

/// A pill the render harness draws hovered: which row, and which of its pills (0 Copy,
/// 1 Show in Finder, 2 Move to Trash).
struct HoveredPill: Equatable {
    let row: Int
    let pill: Int
}
