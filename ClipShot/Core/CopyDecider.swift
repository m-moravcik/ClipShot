import Foundation

/// Decides whether a screenshot may be copied to the clipboard right now.
struct CopyDecider: Sendable {
    static let copyableExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "pdf"]
    static let window: TimeInterval = 30
    static let memory: TimeInterval = 60

    /// A file version handled (copied or seeded), and when.
    private struct Handled: Sendable {
        let modified: Date
        let at: Date
    }

    private var copied: [URL: Handled] = [:]

    /// Files that already exist at launch are never copied.
    mutating func seed(_ files: [CaptureFile], now: Date) {
        for file in files { copied[file.url.standardizedFileURL] = Handled(modified: file.modified, at: now) }
    }

    /// Created and modified within the copy window, and not in the future. `hiddenFor`: how long
    /// the file sat under a hidden temporary name before it appeared (`StagedCaptures`); the
    /// window then counts from when it appeared, not from when it was written.
    static func isFresh(_ file: CaptureFile, now: Date, hiddenFor: TimeInterval = 0) -> Bool {
        let now = now.addingTimeInterval(-hiddenFor)
        return now.timeIntervalSince(file.created) <= window
            && now.timeIntervalSince(file.modified) <= window
            && file.created <= now.addingTimeInterval(1)
    }

    /// A file open in Markup (`EditSession`): it was a screenshot when ClipShot opened it, so
    /// neither its birth time nor the marker (an editor may drop it) counts; only that it was
    /// written within the copy window.
    static func isFreshEdit(_ file: CaptureFile, now: Date, hiddenFor: TimeInterval = 0) -> Bool {
        let now = now.addingTimeInterval(-hiddenFor)
        return now.timeIntervalSince(file.modified) <= window && file.modified <= now.addingTimeInterval(1)
    }

    /// `shouldCopy` without recording the copy. `editing`: the file is in an edit session.
    func wouldCopy(_ file: CaptureFile, now: Date, hiddenFor: TimeInterval = 0, editing: Bool = false) -> Bool {
        let fresh = editing
            ? Self.isFreshEdit(file, now: now, hiddenFor: hiddenFor)
            : file.isScreenshot && Self.isFresh(file, now: now, hiddenFor: hiddenFor)
        guard fresh else { return false }
        return copied[file.url.standardizedFileURL]?.modified != file.modified
    }

    mutating func shouldCopy(
        _ file: CaptureFile, now: Date, hiddenFor: TimeInterval = 0, editing: Bool = false
    ) -> Bool {
        guard wouldCopy(file, now: now, hiddenFor: hiddenFor, editing: editing) else { return false }
        copied[file.url.standardizedFileURL] = Handled(modified: file.modified, at: now)
        return true
    }

    /// Forgets a file `memory` after it was handled, or after a modification time in the future.
    /// Not after it was written: a late capture (`hiddenFor`) is fresh long after that.
    mutating func prune(now: Date) {
        copied = copied.filter { now.timeIntervalSince(max($0.value.modified, $0.value.at)) <= Self.memory }
    }
}
