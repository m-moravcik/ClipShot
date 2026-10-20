import AppKit

/// The display a screenshot was taken on, for placing its floating preview.
///
/// macOS writes `kMDItemScreenCaptureGlobalRect` on every capture (spike F1): a property list
/// array `[x, y, width, height]` in global display coordinates, origin at the top left of the
/// main display, y down. `NSScreen` frames are Cocoa coordinates: origin at the bottom left of
/// the main display, y up.
@MainActor
enum CaptureScreen {
    nonisolated static let globalRectAttribute = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"

    /// The screen holding most of the capture, else the screen with the pointer, else the
    /// main screen.
    static func screen(for url: URL) -> NSScreen? {
        let screens = NSScreen.screens
        let index = index(
            captureRect: globalRect(of: url), screenFrames: screens.map(\.frame),
            mouse: NSEvent.mouseLocation, mainIndex: screens.firstIndex { $0 == NSScreen.main })
        return index.map { screens[$0] } ?? NSScreen.main
    }

    /// Pure: which of `screenFrames` (Cocoa coordinates, the first is the primary display)
    /// to use. Nil only when there are no screens.
    nonisolated static func index(
        captureRect: CGRect?, screenFrames: [CGRect], mouse: CGPoint, mainIndex: Int?
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        if let captureRect, let primary = screenFrames.first {
            let cocoa = CGRect(
                x: captureRect.minX, y: primary.maxY - captureRect.maxY,
                width: captureRect.width, height: captureRect.height)
            let areas = screenFrames.map { frame -> CGFloat in
                let overlap = frame.intersection(cocoa)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
                return best
            }
        }
        if let withMouse = screenFrames.firstIndex(where: { $0.contains(mouse) }) {
            return withMouse
        }
        return mainIndex ?? 0
    }

    /// The capture's rectangle, nil when the attribute is absent or unreadable.
    nonisolated static func globalRect(of url: URL) -> CGRect? {
        let data = url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, globalRectAttribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = buffer.withUnsafeMutableBytes {
                getxattr(path, globalRectAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            return read > 0 ? Data(buffer.prefix(read)) : nil
        }
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let numbers = plist as? [NSNumber], numbers.count == 4
        else { return nil }
        let rect = CGRect(
            x: numbers[0].doubleValue, y: numbers[1].doubleValue,
            width: numbers[2].doubleValue, height: numbers[3].doubleValue)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }
}
