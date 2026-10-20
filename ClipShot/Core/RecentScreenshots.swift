import Foundation

/// What the popover lists of the screenshot folder (Task 12i, superseding Addendum A5's card
/// and strip): the newest screenshots, newest first, the current one on top. Only files that
/// still exist as they were seen: a screenshot moved to the Trash, deleted, renamed or
/// replaced is never shown.
enum RecentScreenshots {
    /// How many rows the list shows: the current screenshot and the 3 before it.
    static let count = 4

    /// Reads the files. Candidates are the screenshots in the ledger (seen being taken, or
    /// older ones the user adopted for cleanup) and the last copied one, each listed once,
    /// by when it was taken. Everything listed is a direct child of `folder`, the folder
    /// being watched, so every action on it (Move to Trash above all) applies and nothing
    /// from an earlier folder stays on show.
    static func select(
        lastCopied: CaptureFile?, ledger: [LedgerEntry], folder: URL?, count: Int = count
    ) -> [CaptureFile] {
        guard count > 0, let folder, let resolved = FolderGuard.strictRealPath(folder.path) else { return [] }
        let inFolder = { (path: String) in (path as NSString).deletingLastPathComponent == resolved }
        // The last copy, as it was copied: its own URL, so it stays the same `CaptureFile`
        // the rest of the app holds (the tour's Try it finds its thumbnail by it). Normally it
        // is in the ledger too; when it is not (an edit saved without the screenshot marker),
        // it is still listed.
        var copied = lastCopied.flatMap { file in
            inFolder(FolderGuard.canonicalPath(file.url)) ? current(file.url, resourceID: file.resourceID) : nil
        }
        // Its ledger entry is the same file; one gone or replaced since leaves the entry be.
        let copiedPath = copied.map { FolderGuard.canonicalPath($0.url) }
        var files: [CaptureFile] = []
        let newestFirst = ledger.sorted { ($0.created, $0.path) > ($1.created, $1.path) }
        for entry in newestFirst where entry.path != copiedPath && inFolder(entry.path) {
            if let file = copied, file.created >= entry.created {
                files.append(file)
                copied = nil
                if files.count == count { return files }
            }
            guard let file = current(URL(fileURLWithPath: entry.path), resourceID: entry.resourceID) else { continue }
            files.append(file)
            if files.count == count { return files }
        }
        if let copied { files.append(copied) }
        return files
    }

    /// The file at `url` now, if it is still the same one.
    private static func current(_ url: URL, resourceID: Data) -> CaptureFile? {
        guard let file = CaptureFile.inspect(url), file.resourceID == resourceID else { return nil }
        return file
    }
}
