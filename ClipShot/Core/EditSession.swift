import Foundation
import Synchronization

/// Screenshots ClipShot opened for editing in Markup (spec Addendum A4).
///
/// A file in a session is exempt from the 30 s copy window until its editor closes or
/// 30 minutes pass, so a long edit still lands on the clipboard when it is saved. Any other
/// old file still never copies. The file matches by its path or by its device and inode, so
/// an editor that saves by replacing the file, or one that keeps the inode, both count.
///
/// Thread-safe: the main actor begins and ends sessions, the coordinator's IO queue asks.
final class EditSession: Sendable {
    static let lifetime: TimeInterval = 30 * 60

    private struct Entry: Sendable {
        let path: String
        let resourceID: Data
        let began: Date
    }

    private let clock: @Sendable () -> Date
    private let entries = Mutex<[Entry]>([])

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    func begin(_ file: CaptureFile) {
        let entry = Entry(path: Self.key(file.url), resourceID: file.resourceID, began: clock())
        entries.withLock { list in
            list.removeAll { $0.path == entry.path }
            list.append(entry)
        }
    }

    /// The editor closed.
    func end(_ file: CaptureFile) {
        let path = Self.key(file.url)
        entries.withLock { list in list.removeAll { $0.path == path || $0.resourceID == file.resourceID } }
    }

    func isEditing(path: String, resourceID: Data) -> Bool {
        guard isActive else { return false }
        // Resolved only while a session is open: the coordinator asks for every file it lists.
        let key = Self.key(URL(fileURLWithPath: path))
        return entries.withLock { list in list.contains { $0.path == key || $0.resourceID == resourceID } }
    }

    /// Some file is open for editing. The coordinator then also scans on its poll, so an
    /// editor that writes in place (no folder event) is still seen.
    var isActive: Bool {
        let now = clock()
        return entries.withLock { list in
            list.removeAll { now.timeIntervalSince($0.began) > Self.lifetime }
            return !list.isEmpty
        }
    }

    func isEditing(_ file: CaptureFile) -> Bool {
        isEditing(path: file.url.path, resourceID: file.resourceID)
    }

    private static func key(_ url: URL) -> String {
        FolderGuard.canonicalPath(url)
    }
}
