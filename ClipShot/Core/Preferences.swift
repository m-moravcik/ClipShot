import Foundation
import Observation

struct Totals: Codable, Equatable, Sendable {
    var copied: Int = 0
    var freedBytes: Int64 = 0
    var trashed: Int = 0
}

/// Where `Preferences` keeps its values. `UserDefaults` in the app; tests use an in-memory
/// store so a run never creates preference files.
protocol PreferenceStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// ClipShot's own settings, persisted under `clipshot.`-prefixed keys.
/// Codable values are stored as JSON `Data`; an unreadable value falls back to its default.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: any PreferenceStore

    var copyEnabled: Bool { didSet { defaults.set(copyEnabled, forKey: Key.copyEnabled) } }
    var copySound: Bool { didSet { defaults.set(copySound, forKey: Key.copySound) } }
    var retention: RetentionPolicy { didSet { store(retention, Key.retention) } }
    var onboardingShown: Bool { didSet { defaults.set(onboardingShown, forKey: Key.onboardingShown) } }
    var launchAtLoginIntent: Bool? {
        didSet {
            if let launchAtLoginIntent {
                defaults.set(launchAtLoginIntent, forKey: Key.launchAtLoginIntent)
            } else {
                defaults.set(nil, forKey: Key.launchAtLoginIntent)
            }
        }
    }
    var lastRetention: RetentionResult? { didSet { store(lastRetention, Key.lastRetention) } }
    var totals: Totals { didSet { store(totals, Key.totals) } }
    var markupTipShown: Bool { didSet { defaults.set(markupTipShown, forKey: Key.markupTipShown) } }
    /// The Preview mode the user chose (Addendum A1). What applies also depends on the
    /// system's `show-thumbnail`: see `PreviewMode.effective`.
    var previewMode: PreviewMode { didSet { defaults.set(previewMode.rawValue, forKey: Key.previewMode) } }
    /// ClipShot has applied its default mode once, at the first start of watching. From then on
    /// it only follows the system pref and the user's choice, and never flips it on its own.
    var previewModeApplied: Bool {
        didSet { defaults.set(previewModeApplied, forKey: Key.previewModeApplied) }
    }

    init(store defaults: any PreferenceStore = UserDefaults.standard) {
        self.defaults = defaults
        copyEnabled = defaults.object(forKey: Key.copyEnabled) as? Bool ?? true
        copySound = defaults.object(forKey: Key.copySound) as? Bool ?? false
        retention = Self.load(RetentionPolicy.self, Key.retention, defaults) ?? .default
        onboardingShown = defaults.object(forKey: Key.onboardingShown) as? Bool ?? false
        launchAtLoginIntent = defaults.object(forKey: Key.launchAtLoginIntent) as? Bool
        lastRetention = Self.load(RetentionResult.self, Key.lastRetention, defaults)
        totals = Self.load(Totals.self, Key.totals, defaults) ?? Totals()
        markupTipShown = defaults.object(forKey: Key.markupTipShown) as? Bool ?? false
        previewMode = (defaults.object(forKey: Key.previewMode) as? String).flatMap(PreviewMode.init(rawValue:)) ?? .clipShot
        previewModeApplied = defaults.object(forKey: Key.previewModeApplied) as? Bool ?? false
    }

    private enum Key {
        static let copyEnabled = "clipshot.copyEnabled"
        static let copySound = "clipshot.copySound"
        static let retention = "clipshot.retention"
        static let onboardingShown = "clipshot.onboardingShown"
        static let launchAtLoginIntent = "clipshot.launchAtLoginIntent"
        static let lastRetention = "clipshot.lastRetention"
        static let totals = "clipshot.totals"
        static let markupTipShown = "clipshot.markupTipShown"
        static let previewMode = "clipshot.previewMode"
        static let previewModeApplied = "clipshot.previewModeApplied"
    }

    private func store<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.set(nil, forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: any PreferenceStore) -> T? {
        guard let data = defaults.object(forKey: key) as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
