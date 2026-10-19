import AppKit

@MainActor
protocol PasteboardWriting: AnyObject {
    func writePNG(_ data: Data) -> Bool
    /// Changes whenever anything writes to the pasteboard, ClipShot or another app.
    var changeCount: Int { get }
}

/// Writes `.png` data only, replacing the pasteboard contents.
@MainActor
final class SystemPasteboard: PasteboardWriting {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func writePNG(_ data: Data) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }
}
