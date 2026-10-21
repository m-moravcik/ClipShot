import Foundation

/// What the popover lists of the screenshot folder (Task 12i, superseding Addendum A5's card
/// and strip): the newest screenshots, newest first, the current one on top. Only files that
/// still exist as they were seen: a screenshot moved to the Trash, deleted, renamed or
/// replaced is never shown.
enum RecentScreenshots {
    /// How many rows the list shows: the current screenshot and the 3 before it.
    static let count = 4
    /// The most screenshots handed out at once: by Get Recent Screenshots
    /// (`AppModel.shortcutMaxCount`) and `clipshot latest -n` (`CLIParser.maxCount`).
    static let maxRequested = 10

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
            inFolder(FolderGuard.canonicalPath(file.url))
                ? current(file.url, resourceID: file.resourceID, requiringMarker: false) : nil
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
            // The ledger is a file of the user's that any process of theirs can write, so an
            // entry alone is no proof: the file itself must still carry the screenshot marker.
            guard let file = current(URL(fileURLWithPath: entry.path), resourceID: entry.resourceID, requiringMarker: true)
            else { continue }
            files.append(file)
            if files.count == count { return files }
        }
        if let copied { files.append(copied) }
        return files
    }

    /// The file at `url` now, if it is still the same one and, with `requiringMarker`, still
    /// a screenshot of this user. The last copy is held in memory only (an edit Markup saved
    /// without the marker stays listed); a ledger entry always needs the marker.
    private static func current(_ url: URL, resourceID: Data, requiringMarker: Bool) -> CaptureFile? {
        guard let file = CaptureFile.inspect(url), file.resourceID == resourceID else { return nil }
        guard file.isScreenshot || !requiringMarker else { return nil }
        return file
    }
}

/// One place in the popover's list: a screenshot's row, or, while its Undo is offered, the
/// strip that stands in for the screenshot just moved to the Trash. Both are named by the
/// file's name, unique in the folder, so a row and the strip that replaces it are the same
/// place and one turns into the other.
enum RecentSlot: Equatable, Identifiable, Sendable {
    case screenshot(CaptureFile)
    case trashed(CaptureFile)

    var file: CaptureFile {
        switch self {
        case .screenshot(let file), .trashed(let file): file
        }
    }

    var id: String { file.url.lastPathComponent }
}

extension RecentScreenshots {
    /// The list's places: `files` (newest first), with the Undo strip for `trashed` where its
    /// row was in time order, never more than `count`. While the strip is there, the older
    /// screenshot that will take the last row waits until Undo is over.
    ///
    /// Where time order puts the strip past the last place: a row that was in the list
    /// (`wasListed`: a newer screenshot arrived meanwhile) keeps the last place, never
    /// jumping; a file that never was (moved from its floating preview) gets the top.
    static func slots(
        files: [CaptureFile], trashed: CaptureFile?, wasListed: Bool = false, count: Int = count
    ) -> [RecentSlot] {
        guard count > 0, let trashed else { return files.prefix(count).map(RecentSlot.screenshot) }
        let name = trashed.url.lastPathComponent
        var slots = files.filter { $0.url.lastPathComponent != name }.map(RecentSlot.screenshot)
        let index = slots.firstIndex { $0.file.created < trashed.created } ?? slots.count
        let place = index < count ? index : (wasListed ? count - 1 : 0)
        slots.insert(.trashed(trashed), at: place)
        return Array(slots.prefix(count))
    }

    /// `file` back among `files` in time order, at most `count`: an Undo puts its row back
    /// in place before the folder is read again.
    static func inserting(_ file: CaptureFile, into files: [CaptureFile], count: Int = count) -> [CaptureFile] {
        let name = file.url.lastPathComponent
        var files = files.filter { $0.url.lastPathComponent != name }
        let index = files.firstIndex { $0.created < file.created } ?? files.count
        files.insert(file, at: index)
        return Array(files.prefix(count))
    }
}
