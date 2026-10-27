import Foundation
import Testing
@testable import ClipShot

struct SingleInstanceTests {
    /// Sleeps by counting, so a test never waits for the grace period.
    private final class FakeClock {
        var slept: Duration = .zero
        func sleep(_ duration: Duration) { slept += duration }
    }

    @Test func noOtherInstance() {
        let clock = FakeClock()
        #expect(SingleInstance.other(among: [], isAlive: { _ in true }, sleep: clock.sleep) == nil)
        #expect(clock.slept == .zero)
    }

    @Test func otherInstanceStillRunningAfterGrace() {
        let clock = FakeClock()
        #expect(SingleInstance.other(among: [42], isAlive: { _ in true }, sleep: clock.sleep) == 42)
        #expect(clock.slept == SingleInstance.grace)
    }

    /// A relaunch can start while the quitting instance is still exiting.
    @Test func quittingInstanceIsWaitedFor() {
        let clock = FakeClock()
        let other = SingleInstance.other(
            among: [42], isAlive: { _ in clock.slept < .milliseconds(500) }, sleep: clock.sleep)
        #expect(other == nil)
        #expect(clock.slept == .milliseconds(500))
    }

    @Test func ownProcessIsNeverAnotherInstance() {
        #expect(!SingleInstance.runningPIDs().contains(getpid()))
    }
}
