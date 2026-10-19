import Foundation

/// Moves a file to the Trash. The only way ClipShot removes anything.
protocol Trashing: Sendable {
    /// Returns where the file went in the Trash, when the system says so, for Undo.
    @discardableResult
    func trash(_ url: URL) throws -> URL?
}

struct FileManagerTrasher: Trashing {
    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
