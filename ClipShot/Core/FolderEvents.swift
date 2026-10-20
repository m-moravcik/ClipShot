import Foundation
import Synchronization

enum WatchError: Error, Equatable, Sendable {
    /// The configured folder does not exist; macOS saves to ~/Desktop meanwhile (spike F14).
    case folderMissing(URL)
    /// The folder exists but cannot be listed.
    case accessDenied(URL)
    /// The folder went away while it was being watched (deleted, moved or moved to the Trash).
    case folderRemoved(URL)
}

/// Tells the caller that something in a folder changed. Events carry no payload: the caller
/// lists the folder itself.
protocol FolderEventSource: Sendable {
    /// Replaces any previous watch. May block on the first access to a TCC-protected folder
    /// (spike F15), so call it off the main actor.
    func start(_ folder: URL, onEvent: @escaping @Sendable () -> Void) throws(WatchError)
    func stop()
}

/// A kqueue vnode source on the folder itself. Spike F4/F5/F7: every capture, including Markup
/// Done, is written as a dot-temp file renamed to the final name, which fires `.write` on the
/// folder; the marker xattrs land 0-54 ms later without an event, so callers must rescan.
/// FSEvents is not used: its events arrived 0.2-300 s late in the spike.
final class DirectoryEventSource: FolderEventSource {
    /// DispatchSource objects are thread-safe; the box only lets the Mutex hold one.
    private struct SourceBox: @unchecked Sendable {
        let source: any DispatchSourceFileSystemObject
    }

    private let queue: DispatchQueue
    private let current = Mutex<SourceBox?>(nil)

    init(queue: DispatchQueue = DispatchQueue(label: "sk.moravcik.ClipShot.folder-events", qos: .utility)) {
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start(_ folder: URL, onEvent: @escaping @Sendable () -> Void) throws(WatchError) {
        stop()
        let path = folder.path
        let fd = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            throw (code == ENOENT || code == ENOTDIR) ? .folderMissing(folder) : .accessDenied(folder)
        }
        // O_EVTONLY can succeed on a folder that cannot be listed; watching it would be useless.
        guard access(path, R_OK | X_OK) == 0 else {
            close(fd)
            throw .accessDenied(folder)
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler { close(fd) }
        let previous = current.withLock { box -> SourceBox? in
            let old = box
            box = SourceBox(source: source)
            return old
        }
        previous?.source.cancel()
        source.resume()
    }

    func stop() {
        let previous = current.withLock { box -> SourceBox? in
            let old = box
            box = nil
            return old
        }
        previous?.source.cancel()
    }
}
