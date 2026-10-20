import Foundation

/// The clock of ClipShot's own short-lived timers: how long a floating preview stays and how
/// long Undo (and a failure note) is offered. The app runs them on the continuous clock;
/// tests drive a manual one, so a lifetime is checked exactly instead of racing real time.
protocol TimerClock: Sendable {
    /// Time since a fixed point of this clock.
    var now: Duration { get }
    /// Returns once `now` has reached `deadline`; throws when the task is cancelled.
    func sleep(until deadline: Duration) async throws
}

/// The continuous clock, which keeps counting while the Mac sleeps, as a preview's or an
/// Undo's few seconds should.
struct SystemTimerClock: TimerClock {
    private let origin = ContinuousClock.now

    init() {}

    var now: Duration { ContinuousClock.now - origin }

    func sleep(until deadline: Duration) async throws {
        try await Task.sleep(until: origin + deadline, clock: .continuous)
    }
}
