import Foundation

/// Snapshot of a candidate capture file. Created by `inspect` (or `stat`), never mutated.
struct CaptureFile: Hashable, Sendable {
    let url: URL
    let created: Date
    let modified: Date
    let size: Int64
    /// Device + inode: equal for the same file (also across rename), different after replace-by-rename.
    let resourceID: Data
    /// Carries the macOS screenshot marker and belongs to this user. False for a file
    /// another user owns, whatever its attributes say (`FileTrust`), and, from `stat`, for
    /// a file whose marker has not been read.
    let isScreenshot: Bool
    /// Owned by the user ClipShot runs as. Only such a file can be a screenshot.
    let isOwnedByUser: Bool

    init(
        url: URL, created: Date, modified: Date, size: Int64, resourceID: Data, isScreenshot: Bool,
        isOwnedByUser: Bool = true
    ) {
        self.url = url
        self.created = created
        self.modified = modified
        self.size = size
        self.resourceID = resourceID
        self.isScreenshot = isScreenshot && isOwnedByUser
        self.isOwnedByUser = isOwnedByUser
    }

    /// nil for non-regular files, symlinks, hidden files, `.mov` and non-image extensions.
    static func inspect(_ url: URL, owner: uid_t = getuid()) -> CaptureFile? {
        stat(url, owner: owner)?.readingMarker(CaptureMarker.isScreenshot)
    }

    /// `inspect` without reading the marker: one `lstat`, no extended attributes, so
    /// `isScreenshot` is false. The copy pass lists a folder this way and reads the marker
    /// only for files it could copy (`readingMarker`).
    static func stat(_ url: URL, owner: uid_t = getuid()) -> CaptureFile? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), CopyDecider.copyableExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        var st = Darwin.stat()
        let rc = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &st)
        }
        guard rc == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var id = Data()
        withUnsafeBytes(of: st.st_dev) { id.append(contentsOf: $0) }
        withUnsafeBytes(of: st.st_ino) { id.append(contentsOf: $0) }
        return CaptureFile(
            url: url,
            created: date(st.st_birthtimespec),
            modified: date(st.st_mtimespec),
            size: Int64(st.st_size),
            resourceID: id,
            isScreenshot: false,
            isOwnedByUser: st.st_uid == owner
        )
    }

    /// The same file with its marker read by `marker`; a file another user owns is never
    /// read and never a screenshot.
    func readingMarker(_ marker: (URL) -> Bool) -> CaptureFile {
        CaptureFile(
            url: url, created: created, modified: modified, size: size, resourceID: resourceID,
            isScreenshot: isOwnedByUser && marker(url), isOwnedByUser: isOwnedByUser)
    }

    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}
