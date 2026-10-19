import Foundation

/// A screenshot ClipShot saw being made (or one the user adopted with a preview).
struct LedgerEntry: Codable, Hashable, Sendable {
    /// Canonical path: resolved parent folder plus the file name.
    let path: String
    let resourceID: Data
    let created: Date
    let size: Int64

    init(path: String, resourceID: Data, created: Date, size: Int64) {
        self.path = path
        self.resourceID = resourceID
        self.created = created
        self.size = size
    }

    init(_ file: CaptureFile) {
        self.init(
            path: FolderGuard.canonicalPath(file.url), resourceID: file.resourceID,
            created: file.created, size: file.size)
    }

    /// Same path **and** same resource identifier.
    func matches(_ file: CaptureFile) -> Bool {
        path == FolderGuard.canonicalPath(file.url) && resourceID == file.resourceID
    }
}

/// The only list of files retention may ever move. JSON, 0600, replaced atomically by rename.
actor ScreenshotLedger {
    private struct Payload: Codable {
        var version: Int
        var entries: [LedgerEntry]
    }

    static let `default` = ScreenshotLedger(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipShot/ledger.json"))

    private let fileURL: URL
    private let log: Log
    private var byPath: [String: LedgerEntry]?

    init(fileURL: URL, log: Log = .shared) {
        self.fileURL = fileURL
        self.log = log
    }

    func entries() -> [LedgerEntry] {
        load().values.sorted { ($0.created, $0.path) < ($1.created, $1.path) }
    }

    func contains(path: String, resourceID: Data) -> Bool {
        load()[path]?.resourceID == resourceID
    }

    /// A fresh screenshot the watcher observed.
    func record(_ file: CaptureFile) {
        var map = load()
        if insert(file, into: &map) { save(map) }
    }

    /// Older screenshots the user chose to clean up after seeing a preview.
    func adopt(_ files: [CaptureFile]) {
        var map = load()
        var changed = false
        for file in files where insert(file, into: &map) { changed = true }
        if changed { save(map) }
    }

    /// Removes an entry after its file went to the Trash.
    func remove(path: String, resourceID: Data) {
        var map = load()
        guard map[path]?.resourceID == resourceID else { return }
        map[path] = nil
        save(map)
    }

    /// Keeps an entry only while `existing` returns the same screenshot at the same path.
    /// A file that is gone, renamed, replaced or no longer marked drops its entry.
    func prune(existing: @Sendable (LedgerEntry) -> CaptureFile?) {
        let map = load()
        let kept = map.filter { _, entry in
            guard let file = existing(entry) else { return false }
            return file.isScreenshot && entry.matches(file)
        }
        if kept.count != map.count { save(kept) }
    }

    func prune() {
        prune { CaptureFile.inspect(URL(fileURLWithPath: $0.path)) }
    }

    // MARK: - Private

    /// Returns true when the map changed. Renamed files (same resource identifier, other path)
    /// are "keep": the old entry is dropped and the new path is not added.
    private func insert(_ file: CaptureFile, into map: inout [String: LedgerEntry]) -> Bool {
        guard file.isScreenshot else { return false }
        let entry = LedgerEntry(file)
        let renamed = map.values.filter { $0.resourceID == entry.resourceID && $0.path != entry.path }
        if !renamed.isEmpty {
            for old in renamed { map[old.path] = nil }
            return true
        }
        guard map[entry.path] != entry else { return false }
        map[entry.path] = entry
        return true
    }

    private func load() -> [String: LedgerEntry] {
        if let byPath { return byPath }
        var map: [String: LedgerEntry] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let payload = try? decoder.decode(Payload.self, from: data) {
                for entry in payload.entries { map[entry.path] = entry }
            } else {
                // Unreadable: start empty, which only ever means "move less".
                let log = log
                Task { await log.error("ledger unreadable, starting empty") }
            }
        }
        byPath = map
        return map
    }

    private func save(_ map: [String: LedgerEntry]) {
        byPath = map
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payload = Payload(version: 1, entries: map.values.sorted { $0.path < $1.path })
        guard let data = try? encoder.encode(payload) else { return }
        if let failure = Self.writeAtomically(data, to: fileURL) {
            let log = log
            Task { await log.error("ledger write failed (errno \(failure))") }
        }
    }

    /// Writes a 0600 sibling, then renames it over the ledger. Returns errno on failure.
    private static func writeAtomically(_ data: Data, to url: URL) -> Int32? {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        if ok { ok = fsync(fd) == 0 }
        let failure = errno
        close(fd)
        guard ok else { return failure }
        return rename(temp.path, url.path) == 0 ? nil : errno
    }
}
