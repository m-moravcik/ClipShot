import Foundation

/// Something the user should look at. Shown in the menu and as the attention icon.
enum Attention: Hashable, Identifiable, Sendable {
    case destinationNotFile
    case folderMissing(URL)
    case folderAccessDenied(URL)
    case couldNotCopy
    case retentionFolderChanged(URL)
    case noTrash(URL)

    var id: String {
        switch self {
        case .destinationNotFile: "destinationNotFile"
        case .folderMissing(let url): "folderMissing:\(url.path)"
        case .folderAccessDenied(let url): "folderAccessDenied:\(url.path)"
        case .couldNotCopy: "couldNotCopy"
        case .retentionFolderChanged(let url): "retentionFolderChanged:\(url.path)"
        case .noTrash(let url): "noTrash:\(url.path)"
        }
    }

    /// Ordered by severity. `.systemOrBroad` raises nothing: retention simply stays off
    /// and Settings explains why.
    static func from(
        destination: CaptureDestination, watchError: WatchError?, copyFailure: Date?,
        retentionRefusal: Refusal?, folder: URL
    ) -> [Attention] {
        var result: [Attention] = []
        if destination != .file { result.append(.destinationNotFile) }
        switch watchError {
        case .accessDenied(let url): result.append(.folderAccessDenied(url))
        case .folderMissing(let url), .folderRemoved(let url): result.append(.folderMissing(url))
        case nil: break
        }
        if copyFailure != nil { result.append(.couldNotCopy) }
        switch retentionRefusal {
        case .noTrash: result.append(.noTrash(folder))
        case .notConfirmed: result.append(.retentionFolderChanged(folder))
        case .systemOrBroad, nil: break
        }
        return result
    }
}
