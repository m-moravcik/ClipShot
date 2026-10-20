import Foundation

/// What `clipshot` (the command line tool) and the running app say to each other over the
/// control socket (Addendum C): one JSON request and one JSON response per connection.
///
/// The app answers only on a Unix domain socket in its own 0700 folder, and only to a peer
/// of the user it runs as (`ControlServer`). Nothing here is reachable from a web page: no
/// URL scheme, no network listener.
enum ControlProtocol {
    /// Raised when a request or a response changes shape. The app refuses any other version,
    /// so a `clipshot` and an app from different releases say so instead of guessing.
    static let version = 1
    /// A request is a command and a path at most; anything larger is refused unread.
    static let maxRequestBytes = 16 * 1_024
    /// A dry run lists at most `RetentionScanner.maxPerRun` paths, well under this.
    static let maxResponseBytes = 4 * 1_024 * 1_024
    static let socketName = "clipshot.sock"
    /// The folder the ledger and the socket live in.
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClipShot", isDirectory: true)
    static var defaultSocketURL: URL { supportDirectory.appendingPathComponent(socketName) }
    /// For tests and development only: `clipshot` looks for the socket and the ledger in this
    /// folder instead. The app always uses `supportDirectory`.
    static let supportDirectoryEnvironmentKey = "CLIPSHOT_SUPPORT_DIR"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One command for the app.
struct ControlRequest: Codable, Equatable, Sendable {
    enum Command: String, Codable, Sendable {
        case status, latest, copy, pause, resume, clean
    }

    var v = ControlProtocol.version
    var command: Command
    /// `latest`: how many, 1 to `AppModel.shortcutMaxCount`.
    var count: Int?
    /// `copy`: an absolute path in the watched folder; nil copies the latest screenshot.
    var path: String?
    /// `clean`: say what would move, move nothing.
    var dryRun: Bool?
}

/// Only the version, read before the rest so a request of another version gets a clear
/// answer even when its shape changed.
struct ControlEnvelope: Decodable {
    let v: Int
}

/// Why a command did nothing. `message` is English, for the terminal (log lines and the
/// command line tool are not localised).
struct ControlFailure: Codable, Equatable, Sendable, Error {
    enum Code: String, Codable, Sendable {
        /// The welcome tour has not been completed.
        case notSetUp
        case noScreenshots
        case copyFailed
        /// `copy PATH`: not a direct child of the watched folder.
        case notInFolder
        /// `copy PATH`: not a file ClipShot reads (a symlink, another user's, too large, not
        /// an image it copies).
        case refusedFile
        case retentionOff
        case retentionRefused
        case retentionChanged
        /// Not JSON, an unknown command or a missing argument.
        case badRequest
        /// Larger than `ControlProtocol.maxRequestBytes`.
        case tooLarge
        /// The request speaks another protocol version.
        case version
    }

    let code: Code
    let message: String
}

/// The app's answer.
struct ControlResponse: Codable, Equatable, Sendable {
    var v = ControlProtocol.version
    var error: ControlFailure?
    var status: ControlStatus?
    var screenshots: [ControlScreenshot]?
    var copied: String?
    var copying: ControlCopying?
    var cleanup: ControlCleanup?

    static func failure(_ code: ControlFailure.Code, _ message: String) -> ControlResponse {
        ControlResponse(error: ControlFailure(code: code, message: message))
    }
}

/// `clipshot status`.
struct ControlStatus: Codable, Equatable, Sendable {
    /// Why copying is off.
    enum PausedBy: String, Codable, Sendable {
        /// The Copy to clipboard switch, by hand (popover, Settings, Shortcuts, `clipshot pause`).
        case manual
        /// A Focus whose filter pauses copying is on.
        case focus
        /// The welcome tour has not been completed: nothing is watched yet.
        case setup
        /// ClipShot is not running.
        case notRunning
    }

    struct Retention: Codable, Equatable, Sendable {
        var enabled: Bool
        var days: Int
        /// Why it would not run on the current folder while on: `notConfirmed`,
        /// `systemOrBroad`, `noTrash` or `folderMissing`. nil when it runs, or is off.
        var refusal: String?

        private enum CodingKeys: String, CodingKey { case enabled, days, refusal }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(days, forKey: .days)
            try c.encode(refusal, forKey: .refusal)
        }
    }

    var running: Bool
    /// The app's version; nil when it is not running.
    var appVersion: String?
    var copying: Bool
    var pausedBy: PausedBy?
    /// The folder screenshots go to, as an absolute path; nil before the tour.
    var folder: String?
    var retention: Retention
    /// The newest screenshot, as `latest` picks it.
    var latest: String?

    private enum CodingKeys: String, CodingKey {
        case running, appVersion, copying, pausedBy, folder, retention, latest
    }

    /// Every key is written, `null` included, so a script reads the same shape whatever the
    /// state.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(running, forKey: .running)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(copying, forKey: .copying)
        try c.encode(pausedBy, forKey: .pausedBy)
        try c.encode(folder, forKey: .folder)
        try c.encode(retention, forKey: .retention)
        try c.encode(latest, forKey: .latest)
    }
}

struct ControlScreenshot: Codable, Equatable, Sendable {
    var path: String
    var created: Date
    var size: Int64
}

/// `clipshot pause` and `resume`.
struct ControlCopying: Codable, Equatable, Sendable {
    var copying: Bool
    /// False when copying already was as asked: nothing changed and Peg plays nothing.
    var changed: Bool
}

/// `clipshot clean`.
struct ControlCleanup: Codable, Equatable, Sendable {
    var dryRun: Bool
    /// Moved to the Trash, or with `dryRun` what would be.
    var count: Int
    var bytes: Int64
    /// With `dryRun`: what would move, oldest first. Empty otherwise.
    var files: [String]
}

extension Refusal {
    /// The name `clipshot status` reports.
    var controlName: String {
        switch self {
        case .systemOrBroad: "systemOrBroad"
        case .noTrash: "noTrash"
        case .notConfirmed: "notConfirmed"
        case .folderMissing: "folderMissing"
        }
    }
}

enum ControlScreenshots {
    /// The newest `count` of `candidates` (already newest first, as `RecentScreenshots.select`
    /// gives them) that `FileTrust` would read: as Get Latest Screenshot skips a refused file
    /// for the next newest, so does `clipshot latest`. Opens each file, reads nothing.
    static func trusted(_ candidates: [CaptureFile], count: Int, policy: FileTrust.Policy = .standard) -> [CaptureFile] {
        var picked: [CaptureFile] = []
        for file in candidates where picked.count < count {
            guard case .success = FileTrust.open(file.url, policy: policy) else { continue }
            picked.append(file)
        }
        return picked
    }

    static func info(_ file: CaptureFile) -> ControlScreenshot {
        ControlScreenshot(path: file.url.path, created: file.created, size: file.size)
    }
}
