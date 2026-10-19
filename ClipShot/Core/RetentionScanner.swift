import Foundation

/// What one retention run would move. Produced only by `RetentionScanner.scan`.
struct RetentionScan: Equatable, Sendable {
    /// The folder, resolved with realpath(3) at scan time.
    let folder: URL
    /// The policy's age limit the scan used; the runner re-checks expiry with it.
    let days: Int
    /// Ledger screenshots past the age limit, oldest first, at most `RetentionScanner.maxPerRun`.
    let expired: [CaptureFile]
    let expiredBytes: Int64
    /// Image files in the folder that are not screenshots (no marker, quarantined, downloaded).
    let skippedUnmarkedImages: Int
    /// Expired screenshots that are not in the ledger (taken before ClipShot, or renamed).
    let olderNotTracked: Int
    let olderNotTrackedBytes: Int64
    /// Expired ledger screenshots left for the next run because of the cap.
    let pending: Int
}

/// Reads the folder and decides what is expired. Never mutates anything.
/// Synchronous file IO: call it off the main actor.
enum RetentionScanner {
    static let maxPerRun = 500
    static let secondsPerDay: TimeInterval = 86_400

    /// Strictly older than `days`; a creation date in the future never expires.
    static func isExpired(_ created: Date, days: Int, now: Date) -> Bool {
        created <= now && now.timeIntervalSince(created) > TimeInterval(days) * secondsPerDay
    }

    static func scan(
        folder: URL, policy: RetentionPolicy, ledger: [LedgerEntry], now: Date, home: URL,
        hasTrash: FolderGuard.TrashLookup = FolderGuard.systemTrashLookup
    ) -> Result<RetentionScan, Refusal> {
        // Resolved once: the guard, the listing and the confirmation all see the same folder,
        // so a symlink flipped mid-scan cannot split them.
        let resolved = URL(fileURLWithPath: CaptureSettings.realPath(folder), isDirectory: true)
        if let refusal = FolderGuard.refusal(resolvedPath: resolved.path, home: home, hasTrash: hasTrash) {
            return .failure(refusal)
        }
        let index = Dictionary(grouping: ledger, by: \.path)
        var tracked: [CaptureFile] = []
        var untracked = 0
        var untrackedBytes: Int64 = 0
        var skipped = 0
        for file in contents(of: resolved) {
            guard file.isScreenshot else {
                skipped += 1
                continue
            }
            guard isExpired(file.created, days: policy.days, now: now) else { continue }
            if index[file.url.path]?.contains(where: { $0.resourceID == file.resourceID }) == true {
                tracked.append(file)
            } else {
                untracked += 1
                untrackedBytes += file.size
            }
        }
        guard policy.enabled else {
            return .success(RetentionScan(
                folder: resolved, days: policy.days, expired: [], expiredBytes: 0,
                skippedUnmarkedImages: skipped, olderNotTracked: untracked, olderNotTrackedBytes: untrackedBytes,
                pending: 0))
        }
        guard let confirmed = policy.confirmed, confirmed.path == resolved.path,
              confirmed == ConfirmedFolder.of(resolved)
        else {
            return .failure(.notConfirmed)
        }
        let batch = Array(oldestFirst(tracked).prefix(maxPerRun))
        return .success(RetentionScan(
            folder: resolved, days: policy.days, expired: batch,
            expiredBytes: batch.reduce(0) { $0 + $1.size },
            skippedUnmarkedImages: skipped, olderNotTracked: untracked, olderNotTrackedBytes: untrackedBytes,
            pending: tracked.count - batch.count))
    }

    /// Expired screenshots not in the ledger, for the one-time "Also clean up N older
    /// screenshots" offer. Adopting them is the user's explicit choice after a preview.
    static func adoptable(folder: URL, ledger: [LedgerEntry], now: Date, policy: RetentionPolicy) -> [CaptureFile] {
        let resolved = URL(fileURLWithPath: CaptureSettings.realPath(folder), isDirectory: true)
        let index = Dictionary(grouping: ledger, by: \.path)
        let files = contents(of: resolved).filter { file in
            file.isScreenshot && isExpired(file.created, days: policy.days, now: now)
                && index[file.url.path]?.contains(where: { $0.resourceID == file.resourceID }) != true
        }
        return oldestFirst(files)
    }

    /// Direct children only. `CaptureFile.inspect` drops directories, symlinks, dot files,
    /// `.mov` and non-image extensions.
    private static func contents(of folder: URL) -> [CaptureFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { CaptureFile.inspect(folder.appendingPathComponent($0, isDirectory: false)) }
    }

    private static func oldestFirst(_ files: [CaptureFile]) -> [CaptureFile] {
        files.sorted { ($0.created, $0.url.path) < ($1.created, $1.url.path) }
    }
}
