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

    mutating func shouldCopy(_ file: CaptureFile, now: Date) -> Bool {
        guard file.isScreenshot,
              now.timeIntervalSince(file.created) <= Self.window,
              now.timeIntervalSince(file.modified) <= Self.window,
              file.created <= now.addingTimeInterval(1)
        else { return false }
        let key = file.url.standardizedFileURL
        if copied[key] == file.modified { return false }
        copied[key] = file.modified
        return true
    }

    mutating func prune(now: Date) {
        copied = copied.filter { now.timeIntervalSince($0.value) <= Self.memory }
    }
}
