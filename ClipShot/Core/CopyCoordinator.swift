import Foundation

/// Watches the screenshot folder, copies each fresh screenshot to the clipboard as PNG and
/// records every fresh screenshot it observes in the retention ledger.
///
/// Isolation: all state lives on the main actor. All file IO (reading the prefs, probing the
/// folder, starting and stopping the event source, listing, inspecting, PNG conversion) runs on
/// one serial `io` queue. The queue keeps those operations in call order, so a `stop` always
/// lands after the `start` it cancels, and a TCC prompt (spike F15) never blocks the main thread.
/// Work started for one folder carries a `generation`; results that come back after a re-target
/// or `stop` are dropped.
@MainActor
final class CopyCoordinator {
    /// Rescans after each folder event. The marker lands 0-54 ms after the final rename and
    /// fires no event (spike F4/F5); the later rescans cover slow writers.
    nonisolated static let rescanOffsets: [Duration] = [.milliseconds(250), .seconds(1), .seconds(3)]
    /// `Cmd+Shift+3` writes one file per display about 10 ms apart, main display first (spike F3).
    nonisolated static let displayGroupWindow: TimeInterval = 1

    var isEnabled = true
    private(set) var lastCopied: CaptureFile? {
        didSet { if lastCopied != oldValue { onStateChange?() } }
    }
    private(set) var watchError: WatchError? {
        didSet { if watchError != oldValue { onStateChange?() } }
    }
    private(set) var lastFailure: Date? {
        didSet { if lastFailure != oldValue { onStateChange?() } }
    }
    /// The folder being watched: the configured one, ~/Desktop while it is missing, or nil.
    private(set) var watchedFolder: URL? {
        didSet { if watchedFolder != oldValue { onStateChange?() } }
    }
    var onCopied: ((CaptureFile) -> Void)?
    /// The screenshot that could not be copied, so "Copy again" can retry that one.
    var onFailure: ((CaptureFile) -> Void)?
    /// Called on the main actor whenever `watchError`, `watchedFolder`, `lastCopied` or
    /// `lastFailure` changes, so an app model can mirror them.
    var onStateChange: (() -> Void)?

    private let settings: CaptureSettings
    private let events: any FolderEventSource
    private let pasteboard: any PasteboardWriting
    private let ledger: ScreenshotLedger
    private let clock: @Sendable () -> Date
    private let pollInterval: Duration
    private let desktop: URL
    private let log: Log
    private let io = DispatchQueue(label: "sk.moravcik.ClipShot.copy-io", qos: .userInitiated)

    private var running = false
    private var generation = 0
    /// The folder the prefs named at the last re-target.
    private var configured: URL?
    /// Device and inode of the watched configured folder, to notice it being replaced.
    private var watchedIdentity: FolderIdentity?
    private var decider = CopyDecider()
    /// Files listed when the current folder was first watched; never recorded in the ledger.
    private var baseline: Set<FileKey> = []
    /// Fresh screenshots already sent to the ledger, with the time they were sent.
    private var recorded: [FileKey: Date] = [:]

    private var seeding = false
    private var passInFlight = false
    private var passQueued = false
    private var refreshInFlight = false
    private var refreshQueued = false
    private var rescanDeadlines: [ContinuousClock.Instant] = []
    private var rescanTask: Task<Void, Never>?
    private var rescanToken = 0
    private var pollTask: Task<Void, Never>?

    init(
        settings: CaptureSettings, events: any FolderEventSource, pasteboard: any PasteboardWriting,
        ledger: ScreenshotLedger, clock: @escaping @Sendable () -> Date, pollInterval: Duration = .seconds(1),
        home: URL = FileManager.default.homeDirectoryForCurrentUser, log: Log = .shared
    ) {
        self.settings = settings
        self.events = events
        self.pasteboard = pasteboard
        self.ledger = ledger
        self.clock = clock
        self.pollInterval = pollInterval
        self.desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        self.log = log
    }

    func start() {
        guard !running else { return }
        running = true
        requestRefresh()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.requestRefresh()
                self.pruneMemory()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        cancelRescans()
        seeding = false
        passQueued = false
        refreshQueued = false
        configured = nil
        watchedFolder = nil
        watchedIdentity = nil
        watchError = nil
        let events = events
        io.async { events.stop() }
    }

    // MARK: - Folder: probe, re-target, errors

    private func requestRefresh() {
        guard running else { return }
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true
        Task {
            await refresh()
            refreshInFlight = false
            if refreshQueued {
                refreshQueued = false
                requestRefresh()
            }
        }
    }

    /// Re-reads the folder pref and re-targets when the folder changed, went away, was replaced,
    /// or while an error is shown and the probe now looks different.
    private func refresh() async {
        // A refresh enqueued just before `stop()` must not read the prefs afterwards.
        guard running else { return }
        let gen = generation
        let settings = settings
        let desktop = desktop
        let probe = await onIO { () -> Probe in
            let folder = settings.folder()
            let state = FolderState.of(folder)
            // ~/Desktop is only touched when it is needed as the fallback.
            guard case .missing = state else { return Probe(configured: folder, state: state, desktop: nil) }
            return Probe(configured: folder, state: state, desktop: .of(desktop))
        }
        guard running, gen == generation else { return }
        if probe.configured != configured {
            await retarget(plan(probe, missing: .folderMissing(probe.configured)))
            return
        }
        // A folder that disappears while it is watched is "removed", one that never was is "missing".
        let removed = watchError == nil || watchError == .folderRemoved(probe.configured)
        let next = plan(probe, missing: removed ? .folderRemoved(probe.configured) : .folderMissing(probe.configured))
        let replaced = next.error == nil && probe.state.identity != watchedIdentity
        guard next.target != watchedFolder || next.error != watchError || replaced else { return }
        await retarget(next)
    }

    private func plan(_ probe: Probe, missing: WatchError) -> Plan {
        switch probe.state {
        case .ok:
            return Plan(configured: probe.configured, target: probe.configured, error: nil)
        case .denied:
            return Plan(configured: probe.configured, target: nil, error: .accessDenied(probe.configured))
        case .missing:
            // macOS saves to ~/Desktop while the folder is missing (spike F14).
            let useDesktop = probe.desktop?.identity != nil
                && desktop.standardizedFileURL.path != probe.configured.standardizedFileURL.path
            return Plan(configured: probe.configured, target: useDesktop ? desktop : nil, error: missing)
        }
    }

    /// Starts watching the plan's folder and seeds the decider with what is already there.
    private func retarget(_ plan: Plan) async {
        generation += 1
        let gen = generation
        cancelRescans()
        passQueued = false
        seeding = true
        configured = plan.configured
        let events = events
        let onEvent = Self.eventHandler(for: self, generation: gen)
        let result = await onIO { () -> Retarget in
            guard let target = plan.target else {
                events.stop()
                return Retarget(watched: nil, identity: nil, error: plan.error, files: [])
            }
            do throws(WatchError) {
                try events.start(target, onEvent: onEvent)
            } catch {
                // A fallback that cannot be watched keeps the configured folder's error.
                return Retarget(watched: nil, identity: nil, error: plan.error ?? error, files: [])
            }
            // Listed after the watch is up, so nothing lands between the two unseen.
            return Retarget(
                watched: target, identity: FolderState.of(target).identity, error: plan.error,
                files: Self.list(target) ?? [])
        }
        guard running, gen == generation else { return }
        seeding = false
        watchedFolder = result.watched
        watchedIdentity = result.identity
        if result.error != watchError { logWatchState(result) }
        watchError = result.error
        decider.seed(result.files)
        baseline = Set(result.files.map(FileKey.init))
        recorded = [:]
        if passQueued {
            passQueued = false
            requestPass()
        }
    }

    private func logWatchState(_ result: Retarget) {
        let message: String
        switch result.error {
        case nil: message = "watching folder"
        case .folderMissing?: message = "folder missing" + (result.watched != nil ? ", watching Desktop" : "")
        case .folderRemoved?: message = "folder removed" + (result.watched != nil ? ", watching Desktop" : "")
        case .accessDenied?: message = "folder access denied"
        }
        let log = log
        Task { await log.info(message) }
    }

    // MARK: - Events and passes

    /// Built outside the main actor: the source calls it on its own queue.
    nonisolated private static func eventHandler(
        for coordinator: CopyCoordinator, generation: Int
    ) -> @Sendable () -> Void {
        { [weak coordinator] in
            Task { @MainActor in coordinator?.folderChanged(generation: generation) }
        }
    }

    private func folderChanged(generation gen: Int) {
        guard running, gen == generation else { return }
        // Rescans first: the event's own pass must not count as the last rescan.
        scheduleRescans()
        requestPass()
    }

    private func scheduleRescans() {
        let now = ContinuousClock.now
        rescanDeadlines.append(contentsOf: Self.rescanOffsets.map { now + $0 })
        rescanDeadlines.sort()
        // Restarted so a deadline earlier than the one being slept on is not missed.
        rescanTask?.cancel()
        rescanToken += 1
        let token = rescanToken
        rescanTask = Task { [weak self] in await self?.runRescans(token: token) }
    }

    private func runRescans(token: Int) async {
        while let next = rescanDeadlines.first {
            do {
                try await Task.sleep(until: next, clock: .continuous)
            } catch {
                return
            }
            let now = ContinuousClock.now
            rescanDeadlines.removeAll { $0 <= now }
            requestPass()
        }
        if token == rescanToken { rescanTask = nil }
    }

    private func cancelRescans() {
        rescanTask?.cancel()
        rescanTask = nil
        rescanToken += 1
        rescanDeadlines.removeAll()
    }

    /// One pass at a time; a request during a pass or a re-target runs once afterwards.
    private func requestPass() {
        guard running else { return }
        if seeding || passInFlight {
            passQueued = true
            return
        }
        guard let folder = watchedFolder else { return }
        passInFlight = true
        let gen = generation
        let decider = decider
        let copying = isEnabled
        // No rescan left after this one: a screenshot that still does not decode has failed.
        let lastRescan = rescanDeadlines.isEmpty
        let clock = clock
        Task {
            let outcome = await onIO {
                Self.scan(folder, decider: decider, copying: copying, lastRescan: lastRescan, now: clock())
            }
            passInFlight = false
            if running, gen == generation {
                finishPass(outcome, copying: copying, lastRescan: lastRescan)
            }
            if passQueued {
                passQueued = false
                requestPass()
            }
        }
    }

    private func finishPass(_ outcome: PassOutcome, copying: Bool, lastRescan: Bool) {
        guard case .listed(let observations) = outcome else {
            // The folder could not be listed: find out whether it is gone or locked.
            requestRefresh()
            return
        }
        let now = clock()
        let copying = copying && isEnabled
        for observation in observations {
            let file = observation.file
            let key = FileKey(file)
            if file.isScreenshot, CopyDecider.isFresh(file, now: now),
               !baseline.contains(key), recorded[key] == nil {
                recorded[key] = now
                let ledger = ledger
                Task { await ledger.record(file) }
            }
            guard copying else {
                // While disabled, everything seen counts as handled: no catch-up on re-enable.
                decider.seed([file])
                continue
            }
            guard decider.wouldCopy(file, now: now) else { continue }
            // Waiting for an earlier file of the same capture to get its marker.
            if observation.deferred { continue }
            if observation.secondaryDisplay {
                _ = decider.shouldCopy(file, now: now)
                continue
            }
            guard let png = observation.png else {
                // Not decodable yet: the next rescan tries again; after the last one it failed.
                if observation.converted, lastRescan {
                    _ = decider.shouldCopy(file, now: now)
                    reportFailure(file)
                }
                continue
            }
            _ = decider.shouldCopy(file, now: now)
            if pasteboard.writePNG(png) {
                lastCopied = file
                onCopied?(file)
                let ext = file.url.pathExtension.lowercased()
                let log = log
                Task { await log.info("copied ext=\(ext)") }
            } else {
                reportFailure(file)
            }
        }
    }

    private func reportFailure(_ file: CaptureFile) {
        lastFailure = clock()
        onFailure?(file)
        let ext = file.url.pathExtension.lowercased()
        let log = log
        Task { await log.error("copy failed ext=\(ext)") }
    }

    private func pruneMemory() {
        let now = clock()
        decider.prune(now: now)
        recorded = recorded.filter { now.timeIntervalSince($0.value) <= CopyDecider.memory }
    }

    // MARK: - Off-main work

    private func onIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let io = io
        return await withCheckedContinuation { continuation in
            io.async { continuation.resume(returning: work()) }
        }
    }

    /// Lists, inspects, applies the multi-display rule and converts what may be copied.
    nonisolated private static func scan(
        _ folder: URL, decider: CopyDecider, copying: Bool, lastRescan: Bool, now: Date
    ) -> PassOutcome {
        guard let files = list(folder) else { return .unreadable }
        var observations = files
            .map { file in
                Observation(file: file, isDisplay: file.isScreenshot && CaptureMarker.captureType(of: file.url) == "display")
            }
            .sorted { ($0.file.created, $0.file.url.path) < ($1.file.created, $1.file.url.path) }
        // Of display captures created within 1 s of each other only the first (main display) is copied.
        var previousDisplay: Date?
        for index in observations.indices where observations[index].isDisplay {
            let created = observations[index].file.created
            if let previous = previousDisplay, created.timeIntervalSince(previous) <= displayGroupWindow {
                observations[index].secondaryDisplay = true
            }
            previousDisplay = created
        }
        // The main display file can still be unmarked (marker up to 54 ms after the rename, F4)
        // when the secondary one, written about 10 ms later (F3), is already marked. A display
        // file waits while a fresh unmarked image created up to 1 s before it may still turn out
        // to be the first display; after the last rescan it no longer waits.
        if !lastRescan {
            let unmarked = observations
                .filter { !$0.file.isScreenshot && CopyDecider.isFresh($0.file, now: now) }
                .map(\.file.created)
            for index in observations.indices
            where observations[index].isDisplay && !observations[index].secondaryDisplay {
                let created = observations[index].file.created
                observations[index].deferred = unmarked.contains {
                    $0 <= created && created.timeIntervalSince($0) <= displayGroupWindow
                }
            }
        }
        guard copying else { return .listed(observations) }
        for index in observations.indices
        where !observations[index].secondaryDisplay && !observations[index].deferred
            && decider.wouldCopy(observations[index].file, now: now) {
            observations[index].converted = true
            observations[index].png = PNGConverter.pngData(from: observations[index].file.url)
        }
        return .listed(observations)
    }

    /// Direct children; dot-files (capture temp names, spike F4) and non-images are skipped.
    /// nil when the folder cannot be listed.
    nonisolated private static func list(_ folder: URL) -> [CaptureFile]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { CaptureFile.inspect(folder.appendingPathComponent($0, isDirectory: false)) }
    }
}

// MARK: - Value types

private struct FolderIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
}

private enum FolderState: Sendable {
    case ok(FolderIdentity), missing, denied

    var identity: FolderIdentity? {
        if case .ok(let identity) = self { identity } else { nil }
    }

    /// Follows symlinks: a configured folder that is a link is watched at its target.
    static func of(_ url: URL) -> FolderState {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (errno == EACCES || errno == EPERM) ? .denied : .missing }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .missing }
        guard access(url.path, R_OK | X_OK) == 0 else { return .denied }
        return .ok(FolderIdentity(device: st.st_dev, inode: st.st_ino))
    }
}

private struct Probe: Sendable {
    let configured: URL
    let state: FolderState
    /// Probed only while the configured folder is missing.
    let desktop: FolderState?
}

private struct Plan: Sendable {
    let configured: URL
    let target: URL?
    let error: WatchError?
}

private struct Retarget: Sendable {
    let watched: URL?
    let identity: FolderIdentity?
    let error: WatchError?
    let files: [CaptureFile]
}

/// One file version: same path, same inode, same modification time.
private struct FileKey: Hashable, Sendable {
    let path: String
    let resourceID: Data
    let modified: Date

    init(_ file: CaptureFile) {
        path = file.url.standardizedFileURL.path
        resourceID = file.resourceID
        modified = file.modified
    }
}

private struct Observation: Sendable {
    let file: CaptureFile
    let isDisplay: Bool
    /// A later display of a multi-display capture: recorded, never copied.
    var secondaryDisplay = false
    /// A display file waiting for an earlier, still unmarked file of the same capture.
    var deferred = false
    /// Conversion was attempted in this pass.
    var converted = false
    var png: Data?

    init(file: CaptureFile, isDisplay: Bool) {
        self.file = file
        self.isDisplay = isDisplay
    }
}

private enum PassOutcome: Sendable {
    case listed([Observation])
    case unreadable
}
