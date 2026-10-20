import Foundation

/// The retention period as Settings > Retention and the welcome tour offer it: the presets,
/// or Custom (any number of days, set with a stepper).
enum RetentionPeriod: Hashable {
    case preset(Int)
    case custom

    static let choices: [RetentionPeriod] = RetentionPolicy.presets.map(RetentionPeriod.preset) + [.custom]

    /// What the picker shows: Custom while the user asked for it, or when the days are no
    /// preset.
    static func of(days: Int, customRequested: Bool) -> RetentionPeriod {
        customRequested || !RetentionPolicy.presets.contains(days) ? .custom : .preset(days)
    }

    /// Applies a choice. A preset sets the days; Custom keeps them and asks for the stepper.
    /// Returns whether Custom is requested from now on. The retention preview follows the
    /// days on its own (`AppModel` re-reads it when the policy changes).
    @MainActor
    static func choose(_ choice: RetentionPeriod, preferences: Preferences) -> Bool {
        switch choice {
        case .custom:
            return true
        case .preset(let days):
            preferences.retention.days = days
            return false
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .preset(let days): Copy.Retention.days(days)
        case .custom: Copy.Retention.custom
        }
    }
}
