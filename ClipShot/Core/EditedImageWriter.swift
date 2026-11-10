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

    /// Writes `data` (any image ImageIO reads) over `url`, encoded in the format `url` has.
    /// `expectedResourceID` is the original's device and inode when the edit began: a file
    /// put at that path since then is not overwritten.
    static func save(
        _ data: Data, over url: URL, expectedResourceID: Data, policy: FileTrust.Policy = .standard
    ) -> Result<Void, Failure> {
        var trust = policy
        trust.expectedResourceID = expectedResourceID
        guard case .success = FileTrust.open(url, policy: trust) else { return .failure(.notTheOriginal) }
        let encoded: Data
        switch encode(data, like: url, policy: policy) {
        case .success(let bytes): encoded = bytes
        case .failure(let failure): return .failure(failure)
        }
        return replace(url, with: encoded)
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
