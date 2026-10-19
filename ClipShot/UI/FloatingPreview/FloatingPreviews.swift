import CoreGraphics
import Observation
import SwiftUI

/// One screenshot in the floating preview stack.
struct PreviewItem: Identifiable, Equatable {
    /// How a preview leaves, which picks its exit motion.
    enum Exit: Equatable {
        /// Its 5 s are up, or a fourth preview pushed it out.
        case timeout
        /// Swiped towards the screen edge; it is already off screen.
        case swipe
        /// Moved to the Trash: it shrinks and drops.
        case trash
        /// Close, or dragged into another app.
        case close
    }

    let id: UUID
    let file: CaptureFile
    /// The decoded preview image; nil for a file that could not be decoded.
    let image: CGImage?
    /// Further displays of the same multi-display capture (spike F3), shown as "+N".
    var extraDisplays = 0
    /// Set just before the item is removed, so the view picks the matching transition.
    var exit: Exit?

    static func == (a: PreviewItem, b: PreviewItem) -> Bool {
        a.id == b.id && a.file == b.file && a.image === b.image
            && a.extraDisplays == b.extraDisplays && a.exit == b.exit
    }
}

/// ClipShot's floating previews (spec Addendum A2): which are on screen, how long each stays,
/// and how each leaves. The panel and the views only draw this; the rules live here so they
/// are tested.
///
/// Newest last: the view stacks them top to bottom, so the newest sits at the bottom and older
/// ones move up. At most three; a fourth pushes the oldest out. Each stays `lifetime`, paused
/// while the pointer is over it.
@MainActor
@Observable
final class FloatingPreviews {
    static let maxVisible = 3
    nonisolated static let defaultLifetime: Duration = .seconds(5)
    /// After the pointer leaves, a preview stays at least this long, so it does not vanish
    /// the moment the pointer moves off it.
    static let afterHover: Duration = .milliseconds(1_500)
    /// Between marking a preview as leaving and removing it: one frame, so the view has drawn
    /// the exit it should animate.
    static let exitHandOff: Duration = .milliseconds(20)

    private(set) var items: [PreviewItem] = []

    /// The previews on screen, without the ones already leaving.
    var visible: [PreviewItem] { items.filter { $0.exit == nil } }

    /// Called after `items` changed, so the panel can show or hide itself.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let lifetime: Duration
    @ObservationIgnored private var deadlines: [UUID: ContinuousClock.Instant] = [:]
    /// Time left for previews under the pointer; their clock is stopped.
    @ObservationIgnored private var paused: [UUID: Duration] = [:]
    /// Later displays seen before the main display's preview was ready.
    @ObservationIgnored private var pendingExtras: [CaptureFile] = []
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(lifetime: Duration = defaultLifetime) {
        self.lifetime = lifetime
    }

    isolated deinit {
        timer?.cancel()
    }

    func show(_ file: CaptureFile, image: CGImage?) {
        if items.contains(where: { $0.file == file && $0.exit == nil }) { return }
        var item = PreviewItem(id: UUID(), file: file, image: image)
        let extras = pendingExtras.filter { Self.sameCapture(main: file, extra: $0) }
        pendingExtras.removeAll { Self.sameCapture(main: file, extra: $0) }
        item.extraDisplays = extras.count
        let overflow = visible.count - Self.maxVisible + 1
        if overflow > 0 {
            for old in visible.prefix(overflow) { dismiss(old.id, .timeout) }
        }
        items.append(item)
        deadlines[item.id] = .now + lifetime
        reschedule()
        onChange?()
    }

    /// A later display of a capture: counted on its main display's preview.
    func addExtraDisplay(_ file: CaptureFile) {
        if let index = items.lastIndex(where: { $0.exit == nil && Self.sameCapture(main: $0.file, extra: file) }) {
            items[index].extraDisplays += 1
            return
        }
        pendingExtras.removeAll { file.created.timeIntervalSince($0.created) > 10 }
        pendingExtras.append(file)
    }

    /// The pointer entered or left a preview: its clock stops, then resumes.
    func setHovering(_ id: UUID, _ hovering: Bool) {
        if hovering {
            guard let deadline = deadlines[id] else { return }
            paused[id] = max(deadline - .now, .zero)
            deadlines[id] = nil
        } else {
            guard let left = paused.removeValue(forKey: id) else { return }
            deadlines[id] = .now + max(left, Self.afterHover)
        }
        reschedule()
    }

    func dismiss(_ id: UUID, _ exit: PreviewItem.Exit) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].exit == nil else { return }
        items[index].exit = exit
        deadlines[id] = nil
        paused[id] = nil
        reschedule()
        Task { [weak self] in
            try? await Task.sleep(for: Self.exitHandOff)
            self?.remove(id)
        }
    }

    /// The file went away (moved to the Trash from elsewhere).
    func dismiss(file: CaptureFile, _ exit: PreviewItem.Exit) {
        for item in items where item.file.url == file.url && item.exit == nil {
            dismiss(item.id, exit)
        }
    }

    /// The mode changed to one without ClipShot's preview, or watching stopped.
    func dismissAll() {
        for item in visible { dismiss(item.id, .close) }
        pendingExtras.removeAll()
    }

    private func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        onChange?()
    }

    /// One task sleeps until the next deadline; it is restarted whenever deadlines change.
    private func reschedule() {
        timer?.cancel()
        guard let next = deadlines.values.min() else {
            timer = nil
            return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.expire()
        }
    }

    private func expire() {
        let now = ContinuousClock.now
        let due = deadlines.filter { $0.value <= now }.map(\.key)
        if due.isEmpty {
            reschedule()
            return
        }
        for id in due { dismiss(id, .timeout) }
    }

    /// `extra` is a later display written with `main` (about 10 ms apart, spike F3).
    private static func sameCapture(main: CaptureFile, extra: CaptureFile) -> Bool {
        let gap = extra.created.timeIntervalSince(main.created)
        return gap >= 0 && gap <= CopyCoordinator.displayGroupWindow && main.url != extra.url
    }
}
