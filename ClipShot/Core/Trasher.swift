import Foundation

/// Moves a file to the Trash. The only way retention removes anything.
protocol Trashing: Sendable {
    func trash(_ url: URL) throws
}

struct FileManagerTrasher: Trashing {
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
