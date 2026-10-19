import Foundation

/// Decides from extended attributes whether a file is a macOS screenshot.
enum CaptureMarker {
    static let captureFlag = "com.apple.metadata:kMDItemIsScreenCapture"
    static let captureType = "com.apple.metadata:kMDItemScreenCaptureType"
    static let quarantine = "com.apple.quarantine"
    static let whereFroms = "com.apple.metadata:kMDItemWhereFroms"

    static func isScreenshot(_ url: URL) -> Bool {
        guard let flag = attribute(captureFlag, of: url), decodesToTrue(flag) else { return false }
        guard attribute(captureType, of: url) != nil else { return false }
        return attribute(quarantine, of: url) == nil && attribute(whereFroms, of: url) == nil
    }

    private static func decodesToTrue(_ data: Data) -> Bool {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return false }
        if let number = value as? NSNumber { return number.intValue == 1 }
        return false
    }

    /// Raw xattr value, nil when absent. Never follows symlinks.
    private static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = buffer.withUnsafeMutableBytes {
                getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            return read >= 0 ? Data(buffer.prefix(read)) : nil
        }
    }
}
