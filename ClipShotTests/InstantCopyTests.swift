import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// Rescan sleeps that a test releases by hand, so rescan timing is checked without depending
/// on how fast the machine is.
final class ManualSleeper: Sendable {
    private struct Waiter: Sendable {
        let id: UUID
        let offset: Duration
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var waiting: [Waiter] = []
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    var waitingCount: Int { state.withLock { $0.waiting.count } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        let offset = deadline - .now
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiting.append(Waiter(id: id, offset: offset, deadline: deadline, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.waiting.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Lets the earliest pending rescan run; returns how long after its scheduling it was due.
    @discardableResult
    func releaseEarliest() -> Duration? {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiting.indices.min(by: { state.waiting[$0].deadline < state.waiting[$1].deadline })
            else { return nil }
            return state.waiting.remove(at: index)
        }
        waiter?.continuation.resume()
        return waiter?.offset
    }
}

@MainActor
struct InstantCopyTests {
    /// The marker lands a few ms after the final rename and fires no folder event (spike F4,
    /// F5). The first rescan after the event copies it, well before the old 250 ms floor.
    @Test func markerJustAfterRenameIsCopiedByTheFirstRescan() async throws {
        let sleeper = ManualSleeper()
        let h = try CoordinatorHarness(sleepUntil: { try await sleeper.sleep(until: $0) })
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let data = CoordinatorHarness.png(70)
        let passes = h.coordinator.passesFinished
        let url = try Fixtures.write(named: "Screenshot.png", contents: data, in: h.folder, marker: .none, captureType: false)
        #expect(await eventually { sleeper.waitingCount == 1 })
        // The event's own pass saw no marker.
        #expect(await eventually { await h.coordinator.passesFinished > passes })
        #expect(h.writes.isEmpty)

        Fixtures.mark(url)
        let due = try #require(sleeper.releaseEarliest())
        #expect(due <= .milliseconds(30), "the first rescan is due 30 ms after the event")
        #expect(due < .milliseconds(250))
        #expect(await eventually { await h.writes == [data] }, "copied by that first rescan alone")
    }

    @Test func rescansStartBeforeTheOldFloor() {
        let offsets = CopyCoordinator.rescanOffsets
        #expect(offsets.first.map { $0 <= .milliseconds(30) } == true)
        #expect(offsets == offsets.sorted())
        #expect(offsets.last == .seconds(3), "slow writers are still covered")
    }
}
