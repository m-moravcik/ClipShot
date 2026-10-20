import Foundation

/// What the popover shows of the screenshot folder (spec Addendum A5): the card and the strip
/// of the previous screenshots under it. Only files that still exist as they were seen: a
/// screenshot moved to the Trash, deleted, renamed or replaced is never shown.
struct RecentScreenshots: Equatable, Sendable {
    /// How many previous screenshots the strip shows.
    static let count = 4

    /// The latest card: the last copied screenshot, or, once that is gone (or nothing was
    /// copied since launch), the newest screenshot in the ledger.
    var card: CaptureFile?
    /// The previous screenshots from the ledger, newest first, without the card's.
    var recent: [CaptureFile]

    /// Reads the files. `folder` limits the strip to direct children of the folder being
    /// watched, so every action on it (Move to Trash above all) applies.
    static func select(
        lastCopied: CaptureFile?, ledger: [LedgerEntry], folder: URL?, count: Int = count
    ) -> RecentScreenshots {
        var card = lastCopied.flatMap { current($0.url, resourceID: $0.resourceID) }
        var recent: [CaptureFile] = []
        guard let folder, let resolved = FolderGuard.strictRealPath(folder.path) else {
            return RecentScreenshots(card: card, recent: [])
        }
        let cardPath = card.map { FolderGuard.canonicalPath($0.url) }
        let newestFirst = ledger.sorted { ($0.created, $0.path) > ($1.created, $1.path) }
        for entry in newestFirst
        where entry.path != cardPath && (entry.path as NSString).deletingLastPathComponent == resolved {
            guard let file = current(URL(fileURLWithPath: entry.path), resourceID: entry.resourceID) else { continue }
            if card == nil {
                card = file
                continue
            }
            recent.append(file)
            if recent.count == count { break }
        }
        return RecentScreenshots(card: card, recent: recent)
    }

    /// The file at `url` now, if it is still the same one.
    private static func current(_ url: URL, resourceID: Data) -> CaptureFile? {
        guard let file = CaptureFile.inspect(url), file.resourceID == resourceID else { return nil }
        return file
    }
}
