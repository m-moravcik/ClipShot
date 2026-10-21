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

    /// The kind, without the folder: what `clipshot status` reports.
    var kind: String {
        switch self {
        case .destinationNotFile: "destinationNotFile"
        case .folderMissing: "folderMissing"
        case .folderAccessDenied: "folderAccessDenied"
        case .couldNotCopy: "couldNotCopy"
        case .retentionFolderChanged: "retentionFolderChanged"
        case .noTrash: "noTrash"
        }
    }

    /// Kinds while which no new screenshot reaches the clipboard: macOS saves no file, or
    /// ClipShot may not read the folder. (A missing folder is followed to the Desktop.)
    static let blockingKinds: Set<String> = ["destinationNotFile", "folderAccessDenied"]

    /// What `clipshot status` says about a kind, in English.
    static func describe(kind: String) -> String {
        switch kind {
        case "destinationNotFile": "macOS saves screenshots to the clipboard or an app, not to a file"
        case "folderAccessDenied": "ClipShot has no access to the screenshot folder"
        case "folderMissing": "the screenshot folder is missing; ClipShot watches the Desktop"
        case "couldNotCopy": "a screenshot could not be copied"
        case "retentionFolderChanged": "cleanup waits until you check the new folder"
        case "noTrash": "the folder's volume has no Trash, so cleanup is off"
        default: kind
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
        case .systemOrBroad, .folderMissing, nil: break
        }
        return result
    }
}
