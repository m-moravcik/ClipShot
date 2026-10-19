import Foundation

/// Access to the `com.apple.screencapture` preference domain.
protocol ScreencapturePreferences: Sendable {
    func value(forKey: String) -> Any?
    func set(_: Any?, forKey: String)
    func synchronize()
}

/// Reads and writes the any-host user domain (spike F11: no host-scoped keys).
/// Synchronizes before every read so another process's change (F12) is seen.
struct SystemScreencapturePreferences: ScreencapturePreferences {
    static let domain = "com.apple.screencapture"

    init() {}

    func value(forKey key: String) -> Any? {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, Self.domain as CFString)
    }

    func set(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }

    func synchronize() {
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }
}
