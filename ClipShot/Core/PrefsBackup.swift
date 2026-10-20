import Foundation

/// One-time backup of the native keys ClipShot may touch.
struct PrefsBackup: Sendable {
    /// Keys backed up before the first write. Restore clears every one of them
    /// that was absent from the backup (spike F16: import merges).
    static let touchedKeys = [
        "location", "location-screenshot", "location-screenrecording",
        "show-thumbnail", "target", "target-screenshot",
    ]

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Writes `keys` unless a backup already exists. Returns true when a backup
    /// is in place afterwards; callers must not write prefs on false.
    @discardableResult
    func saveOnce(_ keys: [String: Any]) -> Bool {
        if FileManager.default.fileExists(atPath: fileURL.path) { return true }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: keys, format: .xml, options: 0
            )
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Returns false when there is no readable backup.
    func restore(into prefs: any ScreencapturePreferences) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let saved = plist as? [String: Any]
        else { return false }
        for key in Self.touchedKeys {
            prefs.set(saved[key], forKey: key)
        }
        return true
    }
}
