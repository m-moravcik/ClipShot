import Foundation

/// A screenshot ClipShot saw being made (or one the user adopted with a preview).
struct LedgerEntry: Codable, Hashable, Sendable {
    /// Canonical path: resolved parent folder plus the file name.
    let path: String
    let resourceID: Data
    let created: Date
    let size: Int64
    /// An older screenshot the user chose to clean up, not one ClipShot saw being taken.
    /// Missing in ledgers written before Addendum A, which only held observed ones.
    let adopted: Bool

    init(path: String, resourceID: Data, created: Date, size: Int64, adopted: Bool = false) {
        self.path = path
        self.resourceID = resourceID
        self.created = created
        self.size = size
        self.adopted = adopted
    }

    init(_ file: CaptureFile, adopted: Bool = false) {
        self.init(
            path: FolderGuard.canonicalPath(file.url), resourceID: file.resourceID,
            created: file.created, size: file.size, adopted: adopted)
    }

    private enum CodingKeys: String, CodingKey { case path, resourceID, created, size, adopted }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            resourceID: try c.decode(Data.self, forKey: .resourceID),
            created: try c.decode(Date.self, forKey: .created),
            size: try c.decode(Int64.self, forKey: .size),
            adopted: try c.decodeIfPresent(Bool.self, forKey: .adopted) ?? false)
    }

    /// What a ledger ClipShot wrote holds: an absolute path without `.` or `..` parts or a
    /// NUL, a device-and-inode resource identifier, a size and a real date.
    var isWellFormed: Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return path.hasPrefix("/") && !path.contains("\0") && !parts.isEmpty
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && resourceID.count == CaptureFile.resourceIDSize
            && size >= 0 && created.timeIntervalSince1970.isFinite
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
        if insert(file, adopted: false, into: &map) { save(map) }
    }

    /// Older screenshots the user chose to clean up after seeing a preview.
    func adopt(_ files: [CaptureFile]) {
        var map = load()
        var changed = false
        for file in files where insert(file, adopted: true, into: &map) { changed = true }
        if changed { save(map) }
    }

    /// A screenshot put back from the Trash (Undo): back in the ledger as it was before.
    func restore(_ file: CaptureFile, adopted: Bool) {
        var map = load()
        if insert(file, adopted: adopted, into: &map) { save(map) }
    }

    /// Removes an entry after its file went to the Trash. Returns the entry removed.
    @discardableResult
    func remove(path: String, resourceID: Data) -> LedgerEntry? {
        var map = load()
        guard let entry = map[path], entry.resourceID == resourceID else { return nil }
        map[path] = nil
        save(map)
        return entry
    }

    /// A screenshot open in Markup was saved by replacing it: a new inode at the same path.
    /// The coordinator calls this only while that file's edit session is open, so the entry
    /// follows the edited file (keeping its original time). A rename, or a replace outside a
    /// session, still leaves the ledger. A replacement without the screenshot marker is not
    /// followed: the ledger only ever holds screenshots.
    func followEdit(_ file: CaptureFile) {
        guard file.isScreenshot else { return }
        var map = load()
        let path = FolderGuard.canonicalPath(file.url)
        guard let old = map[path], old.resourceID != file.resourceID else { return }
        map[path] = LedgerEntry(
            path: path, resourceID: file.resourceID, created: old.created, size: file.size, adopted: old.adopted)
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
    private func insert(_ file: CaptureFile, adopted: Bool, into map: inout [String: LedgerEntry]) -> Bool {
        guard file.isScreenshot else { return false }
        let entry = LedgerEntry(file, adopted: adopted)
        let renamed = map.values.filter { $0.resourceID == entry.resourceID && $0.path != entry.path }
        if !renamed.isEmpty {
            for old in renamed { map[old.path] = nil }
            return true
        }
        guard map[entry.path] != entry else { return false }
        map[entry.path] = entry
        return true
    }

    /// The largest ledger read: about 100,000 entries. A larger file is not ClipShot's.
    static let maxBytes: Int64 = 32 * 1_024 * 1_024

    private func load() -> [String: LedgerEntry] {
        if let byPath { return byPath }
        let (map, problem) = Self.read(fileURL)
        if let problem {
            // Unreadable or refused: start with what was usable, which only ever means "move
            // less" and "list less".
            let log = log
            Task { await log.error("ledger: \(problem)") }
        }
        byPath = map
        return map
    }

    /// The entries of the ledger at `url`, and what was wrong with it, if anything.
    ///
    /// The ledger is a file in the user's Library that any process of theirs can write, so
    /// it is read as untrusted: a regular file of this user (no symlink), at most `maxBytes`,
    /// version 1, and only well-formed entries (`LedgerEntry.isWellFormed`); the rest are
    /// dropped and counted. No entry is proof on its own: whoever lists or copies a file
    /// also checks the screenshot marker on the file itself.
    static func read(_ url: URL) -> (entries: [String: LedgerEntry], problem: String?) {
        var st = stat()
        if lstat(url.path, &st) != 0, errno == ENOENT { return ([:], nil) }
        let data: Data
        switch FileTrust.read(url, policy: FileTrust.Policy(maxBytes: maxBytes)) {
        case .success(let read): data = read
        case .failure(let refusal): return ([:], "refused (\(refusal.rawValue)), starting empty")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(LenientPayload.self, from: data) else {
            return ([:], "unreadable, starting empty")
        }
        guard payload.version == 1 else { return ([:], "unknown version \(payload.version), starting empty") }
        var map: [String: LedgerEntry] = [:]
        var dropped = 0
        for item in payload.entries {
            guard let entry = item.entry, entry.isWellFormed else {
                dropped += 1
                continue
            }
            map[entry.path] = entry
        }
        return (map, dropped > 0 ? "dropped \(dropped) malformed entries" : nil)
    }

    /// The ledger's shape, each entry decoded on its own so one bad entry drops only itself.
    private struct LenientPayload: Decodable {
        let version: Int
        let entries: [LenientEntry]
    }

    private struct LenientEntry: Decodable {
        let entry: LedgerEntry?

        init(from decoder: any Decoder) throws {
            entry = try? LedgerEntry(from: decoder)
        }
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
