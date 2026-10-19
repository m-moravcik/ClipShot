import Foundation
import Observation

struct Totals: Codable, Equatable, Sendable {
    var copied: Int = 0
    var freedBytes: Int64 = 0
    var trashed: Int = 0
}

/// ClipShot's own settings, persisted in UserDefaults under `clipshot.`-prefixed keys.
/// Codable values are stored as JSON `Data`; an unreadable value falls back to its default.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

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
    var firstCopyDone: Bool { didSet { defaults.set(firstCopyDone, forKey: Key.firstCopyDone) } }
    var markupTipShown: Bool { didSet { defaults.set(markupTipShown, forKey: Key.markupTipShown) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyEnabled = defaults.object(forKey: Key.copyEnabled) as? Bool ?? true
        copySound = defaults.bool(forKey: Key.copySound)
        retention = Self.load(RetentionPolicy.self, Key.retention, defaults) ?? .default
        onboardingShown = defaults.bool(forKey: Key.onboardingShown)
        launchAtLoginIntent = defaults.object(forKey: Key.launchAtLoginIntent) as? Bool
        lastRetention = Self.load(RetentionResult.self, Key.lastRetention, defaults)
        totals = Self.load(Totals.self, Key.totals, defaults) ?? Totals()
        firstCopyDone = defaults.bool(forKey: Key.firstCopyDone)
        markupTipShown = defaults.bool(forKey: Key.markupTipShown)
    }

    private enum Key {
        static let copyEnabled = "clipshot.copyEnabled"
        static let copySound = "clipshot.copySound"
        static let retention = "clipshot.retention"
        static let onboardingShown = "clipshot.onboardingShown"
        static let launchAtLoginIntent = "clipshot.launchAtLoginIntent"
        static let lastRetention = "clipshot.lastRetention"
        static let totals = "clipshot.totals"
        static let firstCopyDone = "clipshot.firstCopyDone"
        static let markupTipShown = "clipshot.markupTipShown"
    }

    private func store<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.set(nil, forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
