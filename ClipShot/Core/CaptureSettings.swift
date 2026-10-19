import Foundation

enum CaptureDestination: Equatable, Sendable {
    case file, clipboard, other(String)
}

enum FolderValidation: Equatable, Sendable, Error {
    case ok, notFound, notDirectory, notWritable, forbidden
}

struct CaptureSettings: Sendable {
    private static let locationKeys = ["location", "location-screenshot", "location-screenrecording"]
    private static let forbiddenRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private"]
    /// Per-user temp locations live under /private; they are not system folders.
    private static let allowedUnderPrivate = ["/private/var/folders", "/private/tmp"]

    private let prefs: any ScreencapturePreferences
    private let home: URL
    private let backup: PrefsBackup

    init(prefs: any ScreencapturePreferences, home: URL, backup: PrefsBackup) {
        self.prefs = prefs
        self.home = home
        self.backup = backup
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
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
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
        saveBackup()
        for key in Self.locationKeys {
            prefs.set(value, forKey: key)
        }
    }

    var showThumbnail: Bool {
        get {
            prefs.synchronize()
            return prefs.value(forKey: "show-thumbnail") as? Bool ?? true
        }
        nonmutating set {
            saveBackup()
            prefs.set(newValue, forKey: "show-thumbnail")
        }
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

    func fixDestination() {
        saveBackup()
        prefs.set("file", forKey: "target")
        prefs.set("file", forKey: "target-screenshot")
    }

    private func saveBackup() {
        prefs.synchronize()
        var current: [String: Any] = [:]
        for key in PrefsBackup.touchedKeys {
            if let value = prefs.value(forKey: key) { current[key] = value }
        }
        backup.saveOnce(current)
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
