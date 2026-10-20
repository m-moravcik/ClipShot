import Foundation
@testable import ClipShot

/// A `TimerClock` that only moves when the test says so. A timer waiting on it wakes exactly
/// when `advance` reaches its deadline, so "still there just before its time" is a fact,
/// not a race with the real clock.
final class ManualTimerClock: TimerClock, @unchecked Sendable {
    private typealias Waiter = (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)

    private let lock = NSLock()
    private var current: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    /// Sleeps cancelled before they were registered.
    private var cancelled: Set<UUID> = []

    var now: Duration { lock.withLock { current } }

    /// Timers waiting for a later time.
    var waiting: Int { lock.withLock { waiters.count } }

    /// Moves time on and wakes every timer whose deadline it reached.
    func advance(by duration: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current += duration
            let ids = waiters.filter { $0.value.deadline <= current }.map(\.key)
            return ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }

    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let now: Result<Void, any Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    waiters[id] = (deadline, continuation)
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, any Error>? = lock.withLock {
                if let waiter = waiters.removeValue(forKey: id) { return waiter.continuation }
                cancelled.insert(id)
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
