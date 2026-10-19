import Foundation
@testable import ClipShot

/// A `PreferenceStore` that lives only in memory, so tests never create preference files.
final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    var keys: [String] { Array(values.keys) }

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
