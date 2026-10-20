import Foundation

/// Decides whether a screenshot may be copied to the clipboard right now.
struct CopyDecider: Sendable {
    static let copyableExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "pdf"]
    static let window: TimeInterval = 30
    static let memory: TimeInterval = 60

    private var copied: [URL: Date] = [:]

    /// Files that already exist at launch are never copied.
    mutating func seed(_ files: [CaptureFile]) {
        for file in files { copied[file.url.standardizedFileURL] = file.modified }
    }

    /// Created and modified within the copy window, and not in the future.
    static func isFresh(_ file: CaptureFile, now: Date) -> Bool {
        now.timeIntervalSince(file.created) <= window
            && now.timeIntervalSince(file.modified) <= window
            && file.created <= now.addingTimeInterval(1)
    }

    /// A file open in Markup (`EditSession`): it was a screenshot when ClipShot opened it, so
    /// neither its birth time nor the marker (an editor may drop it) counts; only that it was
    /// written within the copy window.
    static func isFreshEdit(_ file: CaptureFile, now: Date) -> Bool {
        now.timeIntervalSince(file.modified) <= window && file.modified <= now.addingTimeInterval(1)
    }

    /// `shouldCopy` without recording the copy. `editing`: the file is in an edit session.
    func wouldCopy(_ file: CaptureFile, now: Date, editing: Bool = false) -> Bool {
        let fresh = editing
            ? Self.isFreshEdit(file, now: now)
            : file.isScreenshot && Self.isFresh(file, now: now)
        guard fresh else { return false }
        return copied[file.url.standardizedFileURL] != file.modified
    }

    mutating func shouldCopy(_ file: CaptureFile, now: Date, editing: Bool = false) -> Bool {
        guard wouldCopy(file, now: now, editing: editing) else { return false }
        copied[file.url.standardizedFileURL] = file.modified
        return true
    }

    mutating func prune(now: Date) {
        copied = copied.filter { now.timeIntervalSince($0.value) <= Self.memory }
    }
}
