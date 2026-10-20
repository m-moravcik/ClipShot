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
    }

    struct Policy: Sendable {
        /// The largest screenshot read: a full-screen PNG of a 6K display is about 60 MB.
        var maxBytes: Int64 = 256 * 1_024 * 1_024
        /// The most pixels decoded: 100 MP, five 6K displays' worth.
        var maxPixels = 100_000_000
        /// The user a file must belong to.
        var owner: uid_t = getuid()

        static var standard: Policy { Policy() }
    }

    /// The file's bytes, read through one descriptor opened with `O_NOFOLLOW`: what `fstat`
    /// checked (a regular file, the owner, the size) is what is read, whatever happens to
    /// the path meanwhile.
    static func read(_ url: URL, policy: Policy = .standard) -> Result<Data, Refusal> {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { return .failure(errno == ELOOP ? .notRegular : .unreadable) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unreadable) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegular) }
        guard st.st_uid == policy.owner else { return .failure(.notOwned) }
        guard Int64(st.st_size) <= policy.maxBytes else { return .failure(.tooLarge) }
        return readBounded(FileHandle(fileDescriptor: fd, closeOnDealloc: false), maxBytes: policy.maxBytes)
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
