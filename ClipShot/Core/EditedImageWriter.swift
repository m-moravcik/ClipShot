import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves an image that Markup handed back over the screenshot it was opened from (spec
/// Addendum A4), as Markup in Quick Look and Preview.app save: the file then holds the
/// edit, so a later Copy or a second edit sees it.
///
/// The edit replaces the file atomically: it is written to a temporary file on the same
/// volume, given the original's extended attributes (the screenshot marker the ledger
/// needs), permissions and creation date, then renamed over the original. The watcher never
/// sees a half-written image, and the new file is the same screenshot to the ledger
/// (`ScreenshotLedger.followEdit`). Pure and nonisolated: safe off the main actor.
enum EditedImageWriter {
    enum Failure: String, Error, Equatable, Sendable {
        /// The original is no longer the file that was opened, or not this user's.
        case notTheOriginal = "not the file that was opened"
        /// The edit is not an image ImageIO reads, or too large.
        case undecodable = "edit not decodable"
        /// The original's format cannot be written (a PDF capture).
        case unsupportedFormat = "format not writable"
        case writeFailed = "write failed"
    }

    /// What a save did.
    enum Outcome: Equatable, Sendable {
        case saved
        /// The edit has the pixels of a PNG or TIFF file: Done without a change, which on
        /// macOS 27 still hands back the image, re-encoded and larger. The file is left as
        /// it was.
        case unchanged
    }

    /// Writes `data` (any image ImageIO reads) over `url`, encoded in the format `url` has,
    /// unless `url` is a lossless PNG or TIFF and `data` shows its pixels. A JPEG or HEIC is
    /// not compared: Markup re-encodes it on Done, so its pixels differ even without a
    /// change, and a tolerance for that noise could also swallow a faint real edit; it is
    /// always saved. `expectedResourceID` is the original's
    /// device and inode when the edit began: a file put at that path since then is not
    /// overwritten.
    static func save(
        _ data: Data, over url: URL, expectedResourceID: Data, policy: FileTrust.Policy = .standard
    ) -> Result<Outcome, Failure> {
        var trust = policy
        trust.expectedResourceID = expectedResourceID
        guard case .success(let opened) = FileTrust.open(url, policy: trust) else { return .failure(.notTheOriginal) }
        let encoded: Data
        switch encode(data, like: url, policy: policy) {
        case .success(let bytes): encoded = bytes
        case .failure(let failure): return .failure(failure)
        }
        if isLossless(url), case .success(let original) = opened.read(), samePixels(data, original, policy: policy) {
            return .success(.unchanged)
        }
        return replace(url, with: encoded).map { .saved }
    }

    /// Whether `url`'s format keeps pixels exactly through Markup's re-encode.
    private static func isLossless(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .png) || type.conforms(to: .tiff)
    }

    /// Whether two encoded images show the same pixels: the same orientation and size, and
    /// equal once both are drawn into the same 8-bit Display P3 bitmap. The orientation
    /// counts because Markup's Rotate only sets that tag and keeps the stored pixels. Off the
    /// main actor: it decodes both.
    static func samePixels(_ a: Data, _ b: Data, policy: FileTrust.Policy = .standard) -> Bool {
        guard let first = decode(a, policy: policy), let second = decode(b, policy: policy),
              first.orientation == second.orientation,
              first.image.width == second.image.width, first.image.height == second.image.height,
              let firstPixels = bitmap(first.image), let secondPixels = bitmap(second.image)
        else { return false }
        return firstPixels == secondPixels
    }

    /// The stored pixels and the orientation they are shown in (1, up, when untagged).
    private static func decode(_ data: Data, policy: FileTrust.Policy) -> (image: CGImage, orientation: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              FileTrust.allowsPixels(of: source, policy: policy),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (image, properties?[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    private static func bitmap(_ image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: pixels, count: image.width * image.height * 4)
    }

    /// `data` in the format of `url`'s extension: as it is when it already has that format,
    /// re-encoded otherwise.
    static func encode(_ data: Data, like url: URL, policy: FileTrust.Policy = .standard) -> Result<Data, Failure> {
        guard let target = UTType(filenameExtension: url.pathExtension), target.conforms(to: .image),
              !target.conforms(to: .pdf)
        else { return .failure(.unsupportedFormat) }
        guard Int64(data.count) <= policy.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              FileTrust.allowsPixels(of: source, policy: policy),
              let sourceType = CGImageSourceGetType(source) as String?
        else { return .failure(.undecodable) }
        if UTType(sourceType) == target { return .success(data) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return .failure(.undecodable) }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, target.identifier as CFString, 1, nil)
        else { return .failure(.unsupportedFormat) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        CGImageDestinationAddImage(destination, image, properties)
        return CGImageDestinationFinalize(destination) ? .success(out as Data) : .failure(.undecodable)
    }

    private static func replace(_ url: URL, with data: Data) -> Result<Void, Failure> {
        let manager = FileManager.default
        guard let directory = try? manager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        else { return .failure(.writeFailed) }
        // Empty once the rename moved the edit out; rmdir never removes a file. After a
        // failure the temporary file stays in the system's temporary items, which macOS
        // clears.
        defer { _ = directory.withUnsafeFileSystemRepresentation { $0.map { rmdir($0) } } }
        let temporary = directory.appendingPathComponent(url.lastPathComponent)
        guard (try? data.write(to: temporary, options: .withoutOverwriting)) != nil else {
            return .failure(.writeFailed)
        }
        // Extended attributes (the screenshot marker) and permissions. copyfile carries the
        // original's times along with them; the edit is modified now, so that is set again:
        // the watcher copies a file only when its modification time is new.
        let copied = url.withUnsafeFileSystemRepresentation { from in
            temporary.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return copyfile(from, to, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_SECURITY | COPYFILE_NOFOLLOW)) == 0
            }
        }
        guard copied else { return .failure(.writeFailed) }
        var values = URLResourceValues()
        values.contentModificationDate = Date()
        values.creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        var target = temporary
        guard (try? target.setResourceValues(values)) != nil else { return .failure(.writeFailed) }
        let renamed = temporary.withUnsafeFileSystemRepresentation { from in
            url.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return rename(from, to) == 0
            }
        }
        return renamed ? .success(()) : .failure(.writeFailed)
    }
}
