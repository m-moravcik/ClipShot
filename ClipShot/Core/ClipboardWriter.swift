import AppKit

@MainActor
protocol PasteboardWriting: AnyObject {
    func writePNG(_ data: Data) -> Bool
}

/// Writes `.png` data only, replacing the pasteboard contents.
@MainActor
final class SystemPasteboard: PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func writePNG(_ data: Data) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
