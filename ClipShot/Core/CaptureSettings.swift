import Foundation

enum CaptureDestination: Equatable, Sendable {
    case file, clipboard, other(String)
}

enum FolderValidation: Equatable, Sendable, Error {
    case ok, notFound, notDirectory, notWritable, forbidden
    /// The folder is fine, but the one-time backup of the macOS settings could not be
    /// written, so nothing was changed (C-2).
    case backupFailed
}

struct CaptureSettings: Sendable {
    private static let locationKeys = ["location", "location-screenshot", "location-screenrecording"]
    private static let forbiddenRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
    /// Per-user temp locations live under /private; they are not system folders.
    private static let allowedUnderPrivate = ["/private/var/folders", "/private/tmp"]

    private let prefs: any ScreencapturePreferences
    private let home: URL
    private let backup: PrefsBackup
    private let log: Log

    init(prefs: any ScreencapturePreferences, home: URL, backup: PrefsBackup, log: Log = .shared) {
        self.prefs = prefs
        self.home = home
        self.backup = backup
        self.log = log
    }

    /// `location-screenshot`, then `location`, then ~/Desktop. Tilde paths expanded (F12).
    func folder() -> URL {
        prefs.synchronize()
        for key in ["location-screenshot", "location"] {
            if let raw = prefs.value(forKey: key) as? String, !raw.isEmpty {
                return expand(raw)
            }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    func validate(_ url: URL) -> FolderValidation {
        let path = Self.realPath(url)
        let components = path.split(separator: "/")
        if components.contains(where: { $0.hasSuffix(".app") }) { return .forbidden }
        let underAllowed = Self.allowedUnderPrivate.contains { path == $0 || path.hasPrefix($0 + "/") }
        if !underAllowed,
           Self.forbiddenRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return .forbidden
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .notFound }
        guard isDir.boolValue else { return .notDirectory }
        guard FileManager.default.isWritableFile(atPath: path) else { return .notWritable }
        return .ok
    }

    /// nil resets to the system default by removing the three location keys.
    func setFolder(_ url: URL?) throws(FolderValidation) {
        var value: String?
        if let url {
            let result = validate(url)
            guard result == .ok else { throw result }
            value = url.standardizedFileURL.path
        }
        guard saveBackup() else { throw .backupFailed }
        for key in Self.locationKeys {
            prefs.set(value, forKey: key)
        }
    }

    var showThumbnail: Bool {
        prefs.synchronize()
        return prefs.value(forKey: "show-thumbnail") as? Bool ?? true
    }

    /// Writes `show-thumbnail`. False when the backup failed and nothing was written.
    @discardableResult
    func setShowThumbnail(_ on: Bool) -> Bool {
        guard saveBackup() else { return false }
        prefs.set(on, forKey: "show-thumbnail")
        return true
    }

    /// The `type` key, lowercased: png unless the user picked another format.
    func captureFormat() -> String {
        prefs.synchronize()
        guard let raw = prefs.value(forKey: "type") as? String, !raw.isEmpty else { return "png" }
        return raw.lowercased()
    }

    func destination() -> CaptureDestination {
        prefs.synchronize()
        let raw = (prefs.value(forKey: "target-screenshot") as? String)
            ?? (prefs.value(forKey: "target") as? String)
        switch raw {
        case nil, "file": return .file
        case "clipboard": return .clipboard
        case let other?: return .other(other)
        }
    }

    /// Screenshots go to a file again. False when the backup failed and nothing was written.
    @discardableResult
    func fixDestination() -> Bool {
        guard saveBackup() else { return false }
        prefs.set("file", forKey: "target")
        prefs.set("file", forKey: "target-screenshot")
        return true
    }

    /// False when the first-time backup failed; the caller must then not write.
    private func saveBackup() -> Bool {
        prefs.synchronize()
        var current: [String: Any] = [:]
        for key in PrefsBackup.touchedKeys {
            if let value = prefs.value(forKey: key) { current[key] = value }
        }
        guard backup.saveOnce(current) else {
            let log = log
            Task { await log.error("prefs backup failed; settings left unchanged") }
            return false
        }
        return true
    }

    /// realpath(3) keeps /private (resolvingSymlinksInPath strips it). For a path
    /// that does not exist, resolves the deepest existing ancestor and appends the rest.
    static func realPath(_ url: URL) -> String {
        var rest: [String] = []
        var current = url.standardizedFileURL.path
        while true {
            if let resolved = realpath(current, nil) {
                defer { free(resolved) }
                return ([String(cString: resolved)] + rest.reversed())
                    .joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            guard current != "/", !current.isEmpty else { return url.standardizedFileURL.path }
            rest.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private func expand(_ raw: String) -> URL {
        var path = raw
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + "/" + path.dropFirst(2)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}
