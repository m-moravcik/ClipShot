import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ClipShot

enum Fixtures {
    enum Marker { case none, `true`, `false` }

    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-fx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func bplist(_ value: Any) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func setxattr(_ name: String, _ data: Data, on url: URL) {
        let rc = url.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { Darwin.setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        precondition(rc == 0, "setxattr failed")
    }

    /// Writes into a staging dir with xattrs, then renames into `dir`, as screencaptureui does.
    @discardableResult
    static func write(
        named name: String, contents: Data? = nil, in dir: URL,
        marker: Marker = .true, captureType: Bool = true,
        quarantine: Bool = false, whereFroms: Bool = false,
        created: Date? = nil, modified: Date? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.trashItem(at: staging, resultingItemURL: nil) }
        let temp = staging.appendingPathComponent(name)
        try (contents ?? pngImage()).write(to: temp)
        switch marker {
        case .true: setxattr(CaptureMarker.captureFlag, bplist(true), on: temp)
        case .false: setxattr(CaptureMarker.captureFlag, bplist(false), on: temp)
        case .none: break
        }
        if captureType { setxattr(CaptureMarker.captureType, bplist("selection"), on: temp) }
        if quarantine { setxattr(CaptureMarker.quarantine, Data("0083;00000000;Safari;".utf8), on: temp) }
        if whereFroms { setxattr(CaptureMarker.whereFroms, bplist(["https://example.com"]), on: temp) }
        var attrs: [FileAttributeKey: Any] = [:]
        if let created { attrs[.creationDate] = created }
        if let modified { attrs[.modificationDate] = modified }
        if !attrs.isEmpty { try fm.setAttributes(attrs, ofItemAtPath: temp.path) }
        let target = dir.appendingPathComponent(name)
        precondition(rename(temp.path, target.path) == 0, "rename failed")
        return target
    }

    static func image(type: UTType, size: Int = 16) -> Data {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static func pngImage(size: Int = 16) -> Data { image(type: .png, size: size) }
}
