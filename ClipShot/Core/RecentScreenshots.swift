import Foundation

/// What the popover shows of the screenshot folder (spec Addendum A5): the card and the strip
/// of the previous screenshots under it. Only files that still exist as they were seen: a
/// screenshot moved to the Trash, deleted, renamed or replaced is never shown.
struct RecentScreenshots: Equatable, Sendable {
    /// How many previous screenshots the strip shows.
    static let count = 4

    /// The latest card: the last copied screenshot, or, once that is gone (or nothing was
    /// copied since launch), the newest screenshot ClipShot saw being taken. Never an older
    /// file the user adopted for cleanup.
    var card: CaptureFile?
    /// The card shows the last copied screenshot (its button says Copy again), not a fallback.
    var cardIsLastCopied = false
    /// The previous screenshots from the ledger, newest first, without the card's.
    var recent: [CaptureFile]
    /// The files in `recent` the user adopted for cleanup: the strip lists them, the card
    /// never shows them.
    var adopted: Set<CaptureFile> = []

    /// Reads the files. Everything shown is a direct child of `folder`, the folder being
    /// watched, so every action on it (Move to Trash above all) applies and nothing from an
    /// earlier folder stays on show.
    static func select(
        lastCopied: CaptureFile?, ledger: [LedgerEntry], folder: URL?, count: Int = count
    ) -> RecentScreenshots {
        guard let folder, let resolved = FolderGuard.strictRealPath(folder.path) else {
            return RecentScreenshots(card: nil, recent: [])
        }
        let inFolder = { (path: String) in (path as NSString).deletingLastPathComponent == resolved }
        var card = lastCopied.flatMap { copied in
            inFolder(FolderGuard.canonicalPath(copied.url)) ? current(copied.url, resourceID: copied.resourceID) : nil
        }
        let cardIsLastCopied = card != nil
        var recent: [CaptureFile] = []
        var adopted: Set<CaptureFile> = []
        let cardPath = card.map { FolderGuard.canonicalPath($0.url) }
        let newestFirst = ledger.sorted { ($0.created, $0.path) > ($1.created, $1.path) }
        for entry in newestFirst where entry.path != cardPath && inFolder(entry.path) {
            guard let file = current(URL(fileURLWithPath: entry.path), resourceID: entry.resourceID) else { continue }
            if card == nil && !entry.adopted {
                card = file
            } else if recent.count < count {
                recent.append(file)
                if entry.adopted { adopted.insert(file) }
            }
            if card != nil && recent.count == count { break }
        }
        return RecentScreenshots(card: card, cardIsLastCopied: cardIsLastCopied, recent: recent, adopted: adopted)
    }

    /// The file at `url` now, if it is still the same one.
    private static func current(_ url: URL, resourceID: Data) -> CaptureFile? {
        guard let file = CaptureFile.inspect(url), file.resourceID == resourceID else { return nil }
        return file
    }
}
