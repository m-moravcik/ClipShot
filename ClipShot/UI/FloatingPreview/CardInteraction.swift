import AppKit
import SwiftUI
import Synchronization

struct CardMenuItem {
    let title: LocalizedStringResource
    let action: () -> Void
    var separatorBefore = false
}

/// The card's pointer handling, in AppKit, because one press has to become a click (Markup),
/// a swipe towards the screen edge, or a file drag into another app, decided by where the
/// pointer goes first. VoiceOver uses the card's own actions instead.
///
/// The view reaches `overhang` past the card on every side, so the hover (which shows the
/// buttons and stops the timer) still holds over the Close button that sits over the card's
/// corner. Presses only count on the card itself.
struct CardInteraction: NSViewRepresentable {
    let overhang: CGFloat
    let file: CaptureFile
    let image: CGImage?
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onDraggedOut: () -> Void
    let menu: () -> [CardMenuItem]

    func makeNSView(context: Context) -> CardInteractionView {
        let view = CardInteractionView()
        update(view)
        return view
    }

    func updateNSView(_ view: CardInteractionView, context: Context) {
        update(view)
    }

    private func update(_ view: CardInteractionView) {
        view.overhang = overhang
        view.file = file
        view.image = image
        view.onClick = onClick
        view.onHover = onHover
        view.onSwipeChanged = onSwipeChanged
        view.onSwipeEnded = onSwipeEnded
        view.onDraggedOut = onDraggedOut
        view.menuItems = menu
    }
}

final class CardInteractionView: NSView, NSDraggingSource {
    private enum Gesture {
        case idle
        case pressed(NSPoint)
        case swiping(NSPoint)
        case dragging
    }

    /// Movement before a press counts as a drag, as AppKit's own drag threshold.
    private static let threshold: CGFloat = 4

    var overhang: CGFloat = 0
    var file: CaptureFile?
    var image: CGImage?
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onSwipeChanged: (CGFloat) -> Void = { _ in }
    var onSwipeEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onDraggedOut: () -> Void = {}
    var menuItems: () -> [CardMenuItem] = { [] }

    private var gesture = Gesture.idle
    /// Recent swipe positions, for the release velocity.
    private var samples: [(time: TimeInterval, x: CGFloat)] = []
    private var tracking: NSTrackingArea?

    /// The card, without the hover margin around it.
    private var cardRect: NSRect { bounds.insetBy(dx: overhang, dy: overhang) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    /// The hover margin is not the card: a press there goes to what is below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return cardRect.contains(convert(point, from: superview)) ? hit : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        gesture = .pressed(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        switch gesture {
        case .pressed(let start):
            let dx = point.x - start.x, dy = point.y - start.y
            guard hypot(dx, dy) >= Self.threshold else { return }
            if dx > 0 && abs(dx) > abs(dy) {
                gesture = .swiping(start)
                samples = [(event.timestamp, dx)]
                onSwipeChanged(dx)
            } else {
                gesture = .dragging
                beginFileDrag(with: event)
            }
        case .swiping(let start):
            let dx = point.x - start.x
            samples.append((event.timestamp, dx))
            samples.removeAll { event.timestamp - $0.time > 0.1 }
            onSwipeChanged(dx)
        case .idle, .dragging:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch gesture {
        case .pressed:
            onClick()
        case .swiping(let start):
            let dx = event.locationInWindow.x - start.x
            var velocity: CGFloat = 0
            if let first = samples.first, event.timestamp - first.time > 0.005 {
                velocity = (dx - first.x) / CGFloat(event.timestamp - first.time)
            }
            onSwipeEnded(dx, velocity)
        case .idle, .dragging:
            break
        }
        gesture = .idle
        samples = []
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for item in menuItems() {
            if item.separatorBefore { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: String(localized: item.title), action: item.action))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The file URL and the image, as the macOS thumbnail offers them. The image is prepared
    /// off the main thread and handed over only when the receiving app asks for it.
    private func beginFileDrag(with event: NSEvent) {
        guard let file else { return }
        let item = NSPasteboardItem()
        item.setString(file.url.absoluteString, forType: .fileURL)
        item.setDataProvider(DragImageProvider.start(for: file.url), forTypes: [.png])
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let contents = image.map { NSImage(cgImage: $0, size: cardRect.size) }
        dragging.setDraggingFrame(cardRect, contents: contents)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDraggedOut() }
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The PNG of a dragged screenshot, converted on a background thread as the drag starts
/// (a HEIC or JPEG conversion never stalls the drag) and given to the receiving app when it
/// asks. Kept alive until the pasteboard is done with it.
final class DragImageProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    private static let live = Mutex<[ObjectIdentifier: DragImageProvider]>([:])

    private let url: URL
    private let prepared = Mutex<Data?>(nil)

    private init(url: URL) {
        self.url = url
    }

    static func start(for url: URL) -> DragImageProvider {
        let provider = DragImageProvider(url: url)
        live.withLock { $0[ObjectIdentifier(provider)] = provider }
        Task.detached(priority: .userInitiated) {
            let png = PNGConverter.pngData(from: url)
            provider.prepared.withLock { if $0 == nil { $0 = png } }
        }
        return provider
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // Asked before the background conversion finished: convert now.
        guard let png = prepared.withLock({ $0 }) ?? PNGConverter.pngData(from: url) else { return }
        item.setData(png, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        _ = Self.live.withLock { $0.removeValue(forKey: ObjectIdentifier(self)) }
    }
}
