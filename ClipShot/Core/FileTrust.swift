import Foundation
import ImageIO

/// What a file in the screenshot folder must be before ClipShot reads or decodes it.
///
/// The folder may be shared (a network volume, `/Users/Shared`), so a marked image there
/// proves nothing about who wrote it. ClipShot only reads a file that is owned by the user
/// it runs as, opens it without following a symlink, and checks its size and pixel count
/// before ImageIO decodes it. A refused file is skipped quietly; callers log the reason,
/// never the path. Pure and nonisolated: safe off the main actor.
enum FileTrust {
    /// Why a file was not read.
    enum Refusal: String, Error, Equatable, Sendable {
        /// Another user owns it.
        case notOwned = "not owned by this user"
        /// A symbolic link, or not a regular file.
        case notRegular = "not a regular file"
        /// Larger than `Policy.maxBytes`.
        case tooLarge = "file too large"
        /// More pixels than `Policy.maxPixels`, or a PDF page that would raster to more.
        case tooManyPixels = "too many pixels"
        /// Gone, or could not be opened or read.
        case unreadable = "unreadable"
        /// Not the file that was chosen: another file is at its path now.
        case replaced = "not the file that was chosen"
    }

    struct Policy: Sendable {
        /// The largest screenshot read: a full-screen PNG of a 6K display is about 60 MB.
        var maxBytes: Int64 = 256 * 1_024 * 1_024
        /// The most pixels decoded: 100 MP, five 6K displays' worth.
        var maxPixels = 100_000_000
        /// The user a file must belong to.
        var owner: uid_t = getuid()
        /// The file it must be (`CaptureFile.resourceID`, device and inode), checked on the
        /// descriptor that is read; nil for any file.
        var expectedResourceID: Data?

        static var standard: Policy { Policy() }
    }

    /// The file's bytes, read through one descriptor opened with `O_NOFOLLOW`: what `fstat`
    /// checked (a regular file, the owner, the size) is what is read, whatever happens to
    /// the path meanwhile.
    static func read(_ url: URL, policy: Policy = .standard) -> Result<Data, Refusal> {
        open(url, policy: policy).flatMap { $0.read() }
    }

    /// A file opened and checked as `read` does, not read yet. The bytes stay readable
    /// after the path goes away, so a caller can open a file that may vanish at once (a
    /// temporary copy) and read it later, off the main actor.
    final class Opened: Sendable {
        private let fd: Int32
        private let maxBytes: Int64

        fileprivate init(fd: Int32, maxBytes: Int64) {
            self.fd = fd
            self.maxBytes = maxBytes
        }

        deinit { close(fd) }

        /// At most the policy's size, as `read` would.
        func read() -> Result<Data, Refusal> {
            FileTrust.readBounded(FileHandle(fileDescriptor: fd, closeOnDealloc: false), maxBytes: maxBytes)
        }
    }

    /// Opens and checks `url` (one `open` and one `fstat`, no read).
    static func open(_ url: URL, policy: Policy = .standard) -> Result<Opened, Refusal> {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { return .failure(errno == ELOOP ? .notRegular : .unreadable) }
        var st = stat()
        let refusal: Refusal? =
            if fstat(fd, &st) != 0 { .unreadable }
            else if (st.st_mode & S_IFMT) != S_IFREG { .notRegular }
            else if st.st_uid != policy.owner { .notOwned }
            else if Int64(st.st_size) > policy.maxBytes { .tooLarge }
            else if let expected = policy.expectedResourceID,
                    CaptureFile.resourceID(device: st.st_dev, inode: st.st_ino) != expected { .replaced }
            else { nil }
        if let refusal {
            close(fd)
            return .failure(refusal)
        }
        return .success(Opened(fd: fd, maxBytes: policy.maxBytes))
    }

    /// At most `maxBytes` from `handle`. One byte past the limit is enough to tell a file
    /// that grew since `fstat`, so such a file is never read into memory whole.
    static func readBounded(_ handle: FileHandle, maxBytes: Int64) -> Result<Data, Refusal> {
        let limit = Int(clamping: maxBytes)
        guard let data = try? handle.read(upToCount: limit == .max ? limit : limit + 1) ?? Data()
        else { return .failure(.unreadable) }
        return data.count <= limit ? .success(data) : .failure(.tooLarge)
    }

    /// Whether the first image of `source` is small enough to decode. Unknown dimensions
    /// are refused: every image ImageIO can decode reports them.
    static func allowsPixels(of source: CGImageSource, policy: Policy) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return false }
        return allowsPixels(width: width, height: height, policy: policy)
    }

    static func allowsPixels(width: Int, height: Int, policy: Policy) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= policy.maxPixels
    }
}
