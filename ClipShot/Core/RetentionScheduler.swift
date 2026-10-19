import AppKit
import Combine
import Foundation

/// What one retention pass did.
enum RetentionOutcome: Equatable, Sendable {
    /// Retention is off; nothing was read.
    case disabled
    /// The scan refused the folder; nothing was moved.
    case refused(Refusal)
    /// The policy changed while the folder was scanned; nothing was moved.
    case superseded
    case ran(RetentionScan, RetentionResult)
}

/// One retention run, in the only order that is safe: drop ledger entries whose files are
/// gone, scan the current folder off the main actor, then move files only when the scan
/// succeeded and the policy is still the one it scanned with. `RetentionRunner` does not
/// re-check the policy, the confirmation or the Trash itself; this is where that happens.
struct RetentionPass: Sendable {
    let settings: CaptureSettings
    let ledger: ScreenshotLedger
    let runner: RetentionRunner
    let home: URL
    let hasTrash: FolderGuard.TrashLookup

    /// `isCurrent` is asked on the main actor, after the scan, whether `policy` is still in force.
    func run(
        policy: RetentionPolicy, now: Date,
        isCurrent: @escaping @MainActor @Sendable (RetentionPolicy) -> Bool
    ) async -> RetentionOutcome {
        guard policy.enabled else { return .disabled }
        await ledger.prune()
        let entries = await ledger.entries()
        let settings = settings
        let home = home
        let hasTrash = hasTrash
        let scan = await Task.detached(priority: .utility) {
            RetentionScanner.scan(
                folder: settings.folder(), policy: policy, ledger: entries, now: now, home: home,
                hasTrash: hasTrash)
        }.value
        switch scan {
        case .failure(let refusal):
            return .refused(refusal)
        case .success(let scan):
            guard await isCurrent(policy) else { return .superseded }
            return .ran(scan, await runner.run(scan, now: now))
        }
    }
}

/// Runs retention at start, every hour and after wake, strictly one run at a time.
/// A trigger while a run is in flight is folded into a single follow-up run.
@MainActor
final class RetentionScheduler {
    static let interval: TimeInterval = 3_600

    /// The run itself. Set before `start()`.
    var work: (@MainActor () async -> Void)?

    private let hourly: AnyPublisher<Void, Never>
    private let wake: AnyPublisher<Void, Never>
    private var subscriptions: Set<AnyCancellable> = []
    private var running = false
    private var followUp = false
    /// Resumed when the run in flight ends.
    private var current: [CheckedContinuation<Void, Never>] = []
    /// Resumed when the follow-up run ends: they asked after the run in flight began.
    private var next: [CheckedContinuation<Void, Never>] = []

    init(hourly: AnyPublisher<Void, Never>, wake: AnyPublisher<Void, Never>) {
        self.hourly = hourly
        self.wake = wake
    }

    /// A one-hour timer on the main run loop; it exists only while subscribed.
    static func hourlyTimer() -> AnyPublisher<Void, Never> {
        Timer.publish(every: interval, tolerance: 60, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    static func wakeNotifications() -> AnyPublisher<Void, Never> {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        for publisher in [hourly, wake] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in MainActor.assumeIsolated { self?.trigger() } }
                .store(in: &subscriptions)
        }
        trigger()
    }

    /// Stops the timer and the wake trigger. A run in flight finishes.
    func stop() {
        subscriptions.removeAll()
    }

    func trigger() {
        request(nil)
    }

    /// Returns once a run that started after this call has finished.
    func runNow() async {
        await withCheckedContinuation { request($0) }
    }

    private func request(_ waiter: CheckedContinuation<Void, Never>?) {
        if running {
            followUp = true
            if let waiter { next.append(waiter) }
            return
        }
        running = true
        if let waiter { current.append(waiter) }
        Task { await loop() }
    }

    private func loop() async {
        while true {
            await work?()
            let done = current
            current = []
            done.forEach { $0.resume() }
            guard followUp else { break }
            followUp = false
            current = next
            next = []
        }
        running = false
    }
}
