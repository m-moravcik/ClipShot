import Foundation

struct RetentionResult: Codable, Equatable, Sendable {
    let moved: Int
    let movedBytes: Int64
    let failed: Int
    let at: Date
}

/// Moves the files of a scan to the Trash. Every file is re-checked right before it is
/// moved; anything that changed since the scan is left alone.
actor RetentionRunner {
    private let trasher: any Trashing
    private let ledger: ScreenshotLedger
    private let home: URL
    private let log: Log

    init(
        trasher: any Trashing, ledger: ScreenshotLedger,
        home: URL = FileManager.default.homeDirectoryForCurrentUser, log: Log = .shared
    ) {
        self.trasher = trasher
        self.ledger = ledger
        self.home = home
        self.log = log
    }

    func run(_ scan: RetentionScan, now: Date) async -> RetentionResult {
        var moved = 0
        var movedBytes: Int64 = 0
        var failed = 0
        var skipped = 0
        var byExtension: [String: Int] = [:]
        for file in scan.expired.prefix(RetentionScanner.maxPerRun) {
            // Fresh ledger check first; no suspension point between the checks below and the move.
            guard await ledger.contains(path: file.url.path, resourceID: file.resourceID),
                  let current = Self.revalidate(file, in: scan, now: now, home: home)
            else {
                skipped += 1
                continue
            }
            do {
                try trasher.trash(current.url)
            } catch {
                failed += 1
                continue
            }
            moved += 1
            movedBytes += current.size
            byExtension[current.url.pathExtension.lowercased(), default: 0] += 1
            await ledger.remove(path: file.url.path, resourceID: file.resourceID)
        }
        let kinds = byExtension.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        await log.info("retention moved \(moved) [\(kinds)], skipped \(skipped), failed \(failed), pending \(scan.pending)")
        return RetentionResult(moved: moved, movedBytes: movedBytes, failed: failed, at: now)
    }

    /// The file as it is now, or nil when it must not be moved.
    static func revalidate(_ file: CaptureFile, in scan: RetentionScan, now: Date, home: URL) -> CaptureFile? {
        let folder = scan.folder.path
        // The folder is still the resolved, non-broad folder the scan read.
        guard FolderGuard.strictRealPath(folder) == folder,
              !FolderGuard.isBroad(folder, home: CaptureSettings.realPath(home))
        else { return nil }
        // A direct child, spelled canonically, whose parent still resolves to the folder.
        let parent = file.url.deletingLastPathComponent().path
        guard parent == folder, FolderGuard.strictRealPath(parent) == folder,
              file.url.path == FolderGuard.canonicalPath(file.url)
        else { return nil }
        // lstat: a regular file (not a symlink), image extension, still a screenshot,
        // the same inode and still expired.
        guard let current = CaptureFile.inspect(file.url),
              current.isScreenshot,
              current.resourceID == file.resourceID,
              RetentionScanner.isExpired(current.created, days: scan.days, now: now)
        else { return nil }
        return current
    }
}
