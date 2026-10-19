import Foundation

/// Snapshot of a candidate capture file. Created by `inspect`, never mutated.
struct CaptureFile: Hashable, Sendable {
    let url: URL
    let created: Date
    let modified: Date
    let size: Int64
    /// Device + inode: equal for the same file (also across rename), different after replace-by-rename.
    let resourceID: Data
    let isScreenshot: Bool

    /// nil for non-regular files, symlinks, hidden files, `.mov` and non-image extensions.
    static func inspect(_ url: URL) -> CaptureFile? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), CopyDecider.copyableExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        var st = stat()
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
            isScreenshot: CaptureMarker.isScreenshot(url)
        )
    }

    private static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}
