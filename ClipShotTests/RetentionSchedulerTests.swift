import Combine
import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// A work closure the test can hold open, to see what the scheduler does while a run is in flight.
@MainActor
final class GatedWork {
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    var holding = false
    private var gate: [CheckedContinuation<Void, Never>] = []

    func run() async {
        started += 1
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        if holding { await withCheckedContinuation { gate.append($0) } }
        concurrent -= 1
        finished += 1
    }

    func release() {
        holding = false
        let waiting = gate
        gate = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
struct RetentionSchedulerTests {
    private func makeScheduler(_ work: GatedWork) -> (RetentionScheduler, PassthroughSubject<Void, Never>, PassthroughSubject<Void, Never>) {
        let hourly = PassthroughSubject<Void, Never>()
        let wake = PassthroughSubject<Void, Never>()
        let scheduler = RetentionScheduler(hourly: hourly.eraseToAnyPublisher(), wake: wake.eraseToAnyPublisher())
        scheduler.work = { await work.run() }
        return (scheduler, hourly, wake)
    }

    @Test func runsAtStartHourlyAndOnWake() async {
        let work = GatedWork()
        let (scheduler, hourly, wake) = makeScheduler(work)
        defer { scheduler.stop() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(work.started == 0, "nothing runs before start")
        scheduler.start()
        #expect(await eventually { await work.finished == 1 })
        hourly.send()
        #expect(await eventually { await work.finished == 2 })
        wake.send()
        #expect(await eventually { await work.finished == 3 })
        scheduler.stop()
        hourly.send()
        wake.send()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(work.finished == 3, "nothing runs after stop")
    }

    @Test func triggersWhileRunningCoalesceIntoOneFollowUp() async {
        let work = GatedWork()
        work.holding = true
        let (scheduler, hourly, wake) = makeScheduler(work)
        defer { scheduler.stop() }
        scheduler.start()
        #expect(await eventually { await work.started == 1 })
        hourly.send()
        wake.send()
        scheduler.trigger()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(work.started == 1, "no second run while the first is in flight")
        work.release()
        #expect(await eventually { await work.finished == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(work.finished == 2)
        #expect(work.maxConcurrent == 1)
    }

    @Test func runNowWaitsForARunThatStartsAfterTheCall() async {
        let work = GatedWork()
        work.holding = true
        let (scheduler, _, _) = makeScheduler(work)
        scheduler.trigger()
        #expect(await eventually { await work.started == 1 })
        let done = Mutex(false)
        let waiter = Task { @MainActor in
            await scheduler.runNow()
            done.withLock { $0 = true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        work.release()
        // The run in flight began before the request, so runNow waits for the follow-up.
        await waiter.value
        #expect(done.withLock { $0 })
        #expect(work.finished == 2)
    }
}

/// The pass itself: prune, scan, then move only on success.
struct RetentionPassTests {
    private struct Setup {
        let dir: URL
        let ledger: ScreenshotLedger
        let trasher: FakeTrasher
        let pass: RetentionPass
        let now: Date
    }

    private func setUp(names: [String] = ["a.png", "b.png"], folder: URL? = nil) async throws -> Setup {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let ledger = try RT.ledger()
        for name in names {
            await ledger.record(RT.file(try RT.shot(name, in: dir, age: 40 * RT.day, now: now)))
        }
        let prefs = FakeScreencapturePreferences(["location": (folder ?? dir).path])
        let settings = CaptureSettings(
            prefs: prefs, home: RT.home, backup: PrefsBackup(fileURL: dir.appendingPathComponent("backup.plist")),
            log: try RT.testLog())
        let trasher = try FakeTrasher()
        let pass = RetentionPass(
            settings: settings, ledger: ledger, runner: try RT.runner(trasher, ledger), home: RT.home,
            hasTrash: RT.hasTrash)
        return Setup(dir: dir, ledger: ledger, trasher: trasher, pass: pass, now: now)
    }

    @Test func movesLedgerScreenshotsWhenEnabledAndConfirmed() async throws {
        let s = try await setUp()
        let outcome = await s.pass.run(policy: RT.policy(s.dir), now: s.now) { _ in true }
        guard case .ran(let scan, let result) = outcome else {
            Issue.record("expected a run, got \(outcome)")
            return
        }
        #expect(scan.expired.count == 2)
        #expect(result.moved == 2)
        #expect(Set(s.trasher.trashed) == ["a.png", "b.png"])
    }

    @Test func neverRunsWhenDisabled() async throws {
        let s = try await setUp()
        let outcome = await s.pass.run(policy: RT.policy(s.dir, enabled: false), now: s.now) { _ in true }
        #expect(outcome == .disabled)
        #expect(s.trasher.trashed.isEmpty)
    }

    @Test func refusedScanMovesNothing() async throws {
        let other = try Fixtures.makeDir()
        let s = try await setUp(folder: other)
        // Confirmed for `dir`, but the screenshot folder is now `other`.
        let outcome = await s.pass.run(policy: RT.policy(s.dir), now: s.now) { _ in true }
        #expect(outcome == .refused(.notConfirmed))
        #expect(s.trasher.trashed.isEmpty)
    }

    @Test func policyChangedDuringScanMovesNothing() async throws {
        let s = try await setUp()
        let outcome = await s.pass.run(policy: RT.policy(s.dir), now: s.now) { _ in false }
        #expect(outcome == .superseded)
        #expect(s.trasher.trashed.isEmpty)
        #expect(await s.ledger.entries().count == 2)
    }

    @Test func prunesGoneEntriesBeforeScanning() async throws {
        let s = try await setUp()
        let gone = s.dir.appendingPathComponent("a.png")
        let away = try Fixtures.makeDir().appendingPathComponent("a.png")
        #expect(rename(gone.path, away.path) == 0)
        _ = await s.pass.run(policy: RT.policy(s.dir), now: s.now) { _ in true }
        #expect(s.trasher.trashed == ["b.png"])
        #expect(await s.ledger.entries().isEmpty)
    }
}
