import Foundation
import Synchronization
@testable import ClipShot

final class FakeScreencapturePreferences: ScreencapturePreferences {
    /// Property-list values only (String, Bool, Int), so crossing the lock is safe.
    private struct Box: @unchecked Sendable { var value: Any? }

    private struct State: Sendable {
        var values: [String: Box] = [:]
        var synchronizeCount = 0
    }

    private let state = Mutex(State())

    init(_ initial: [String: Any] = [:]) {
        let boxed = initial.mapValues { Box(value: $0) }
        state.withLock { $0.values = boxed }
    }

    subscript(key: String) -> Any? {
        get { state.withLock { $0.values[key]?.value } }
        set {
            let box = newValue.map { Box(value: $0) }
            state.withLock { $0.values[key] = box }
        }
    }

    var synchronizeCount: Int { state.withLock { $0.synchronizeCount } }

    func value(forKey key: String) -> Any? { self[key] }
    func set(_ value: Any?, forKey key: String) { self[key] = value }
    func synchronize() { state.withLock { $0.synchronizeCount += 1 } }
}
