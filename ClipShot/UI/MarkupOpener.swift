import AppKit

/// How a Markup edit ended.
enum MarkupResult: Equatable, Sendable {
    /// The editor wrote the file in place; the watcher copies it (it is in an edit session).
    case savedInPlace
    /// The editor handed back an edited copy instead; ClipShot copies this image and leaves
    /// the original file alone.
    case savedCopy(Data)
    /// Done or Cancel without a change.
    case closed
    /// The Markup extension was not available, so Preview.app opened the file. ClipShot does
    /// not learn when Preview closes; the edit session ends after 30 minutes.
    case openedInPreview
    case failed
}

extension MarkupResult {
    /// For the log: which way an edit ended, never a path.
    var logName: String {
        switch self {
        case .savedInPlace: "done in place"
        case .savedCopy: "done as copy"
        case .closed: "closed"
        case .openedInPreview: "opened in Preview"
        case .failed: "failed"
        }
    }
}

/// Opens a screenshot for annotation in macOS Markup (spec Addendum A4, spike F-markup): the
/// system Markup extension through `NSSharingService`, else Preview.app.
@MainActor
final class MarkupOpener: NSObject, NSSharingServiceDelegate {
    static let extensionIdentifier = "com.apple.MarkupUI.Markup"
    static let previewIdentifier = "com.apple.Preview"

    private struct Edit {
        let url: URL
        let modified: Date?
        let service: NSSharingService
        let host: NSWindow
        let completion: @MainActor (MarkupResult) -> Void
    }

    private var edit: Edit?
    private let makeService: @MainActor (String) -> NSSharingService?
    private let openPreview: @MainActor (URL) -> Bool

    /// `makeService` and `openPreview` are seams for tests: the extension may be missing (it
    /// was verified on macOS 27 only; F-markup), and then Preview.app opens the file.
    init(
        makeService: @escaping @MainActor (String) -> NSSharingService? = { NSSharingService(named: NSSharingService.Name($0)) },
        openPreview: @escaping @MainActor (URL) -> Bool = MarkupOpener.openInPreview
    ) {
        self.makeService = makeService
        self.openPreview = openPreview
    }

    /// One edit at a time; opening another file ends the previous edit as closed.
    func open(_ url: URL, completion: @escaping @MainActor (MarkupResult) -> Void) {
        finish(.closed)
        guard let service = makeService(Self.extensionIdentifier), service.canPerform(withItems: [url]) else {
            completion(openPreview(url) ? .openedInPreview : .failed)
            return
        }
        let host = Self.hostWindow(for: url)
        edit = Edit(url: url, modified: Self.modified(url), service: service, host: host, completion: completion)
        service.delegate = self
        NSApp.activate()
        host.makeKeyAndOrderFront(nil)
        service.perform(withItems: [url])
    }

    private func finish(_ result: MarkupResult) {
        guard let edit else { return }
        self.edit = nil
        edit.service.delegate = nil
        edit.host.orderOut(nil)
        edit.completion(result)
    }

    static func openInPreview(_ url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.previewIdentifier) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        return true
    }

    /// The editor attaches to a window of ours: an invisible one where the screenshot was
    /// taken, the size the editor should have.
    private static func hostWindow(for url: URL) -> NSWindow {
        let screen = CaptureScreen.screen(for: url)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(1000, screen.width * 0.8), height: min(720, screen.height * 0.8))
        let frame = NSRect(
            x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
            width: size.width, height: size.height)
        let window = MarkupHostWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    nonisolated private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - NSSharingServiceDelegate

    nonisolated func sharingService(
        _ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        MainActor.assumeIsolated { edit?.host }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        // Read a returned copy now: it may live in a temporary place the extension cleans up.
        let urls = items.compactMap(Self.fileURL)
        MainActor.assumeIsolated {
            guard let edit else { return }
            if Self.modified(edit.url) != edit.modified {
                finish(.savedInPlace)
            } else if let copy = urls.first(where: { $0.standardizedFileURL != edit.url.standardizedFileURL }),
                      let data = try? Data(contentsOf: copy) {
                finish(.savedCopy(data))
            } else {
                finish(.closed)
            }
        }
    }

    nonisolated func sharingService(
        _ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error
    ) {
        let cancelled = (error as NSError).domain == NSCocoaErrorDomain
            && (error as NSError).code == NSUserCancelledError
        MainActor.assumeIsolated {
            guard let edit else { return }
            if cancelled {
                finish(.closed)
            } else {
                // The extension could not run: Preview.app is the last native path.
                let url = edit.url
                finish(openPreview(url) ? .openedInPreview : .failed)
            }
        }
    }

    nonisolated private static func fileURL(_ item: Any) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, url.isFileURL { return url as URL }
        return nil
    }
}

/// Borderless, so it stays invisible, but able to become key: the editor attached to it takes
/// the keyboard for text annotations.
private final class MarkupHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
