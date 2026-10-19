import Foundation

/// App log: `<ISO8601> <LEVEL> <message>`, 0600, rolled to `<name>.1` by rename.
/// Messages carry counts and extensions only, never paths.
actor Log {
    static let shared = Log(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/clipshot.log")
    )

    private let fileURL: URL
    private let maxBytes: Int
    private let formatter = ISO8601DateFormatter()

    init(fileURL: URL, maxBytes: Int = 512 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    func info(_ message: String) { write("INFO", message) }
    func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let fm = FileManager.default
        let line = "\(formatter.string(from: Date())) \(level) \(message)\n"
        let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + line.utf8.count > maxBytes, size > 0 { roll() }
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func roll() {
        let fm = FileManager.default
        let rolled = fileURL.appendingPathExtension("1")
        // rename(2) replaces an existing destination atomically.
        if rename(fileURL.path, rolled.path) != 0 {
            _ = try? fm.replaceItemAt(rolled, withItemAt: fileURL)
        }
    }
}
