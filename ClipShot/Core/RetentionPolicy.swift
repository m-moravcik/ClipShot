import Foundation

/// The screenshot folder the user saw a retention preview for. Retention pauses when
/// the current folder resolves to anything else.
struct ConfirmedFolder: Codable, Equatable, Sendable {
    /// realpath(3) of the folder: symlinks resolved, `/private` kept, no trailing slash.
    let path: String
    /// Volume UUID, or the device number when the volume has none.
    let volumeID: String

    /// nil when the folder does not exist or is not a directory.
    static func of(_ url: URL) -> ConfirmedFolder? {
        guard let path = FolderGuard.strictRealPath(url.standardizedFileURL.path) else { return nil }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let uuid = (try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return ConfirmedFolder(path: path, volumeID: uuid ?? "dev:\(st.st_dev)")
    }
}

struct RetentionPolicy: Codable, Equatable, Sendable {
    static let presets = [7, 14, 30, 60, 90]
    static let dayRange = 1...3650
    /// Off on a fresh install; 30 days once turned on.
    static let `default` = RetentionPolicy(enabled: false, days: 30, confirmed: nil)

    var enabled: Bool
    var days: Int { didSet { days = Self.clamp(days) } }
    var confirmed: ConfirmedFolder?

    init(enabled: Bool, days: Int, confirmed: ConfirmedFolder?) {
        self.enabled = enabled
        self.days = Self.clamp(days)
        self.confirmed = confirmed
    }

    private enum CodingKeys: String, CodingKey { case enabled, days, confirmed }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decode(Bool.self, forKey: .enabled),
            days: try c.decode(Int.self, forKey: .days),
            confirmed: try c.decodeIfPresent(ConfirmedFolder.self, forKey: .confirmed))
    }

    private static func clamp(_ days: Int) -> Int {
        min(max(days, dayRange.lowerBound), dayRange.upperBound)
    }
}
