import Foundation
import Synchronization

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
    /// Rescans after each folder event. The marker lands 0-54 ms after the final rename,
    /// typically about 2 ms, and fires no event (spike F4/F5): the 30 and 80 ms rescans copy
    /// it at once (Addendum A), the later ones cover slow writers.
    nonisolated static let rescanOffsets: [Duration] = [
        .milliseconds(30), .milliseconds(80), .milliseconds(250), .seconds(1), .seconds(3),
    ]
    /// `Cmd+Shift+3` writes one file per display about 10 ms apart, main display first (spike F3).
    nonisolated static let displayGroupWindow: TimeInterval = 1
    /// How late the 1 s poll may fire, so macOS can coalesce its wake-ups with others.
    nonisolated static let pollTolerance = 0.25

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
    /// A later display of a multi-display capture (F3): recorded, never copied. The floating
    /// preview counts it as "+1".
    var onExtraDisplay: ((CaptureFile) -> Void)?
    /// Called on the main actor whenever `watchError`, `watchedFolder`, `lastCopied` or
    /// `lastFailure` changes, so an app model can mirror them.
    var onStateChange: (() -> Void)?

    private let settings: CaptureSettings
    private let events: any FolderEventSource
    private let pasteboard: any PasteboardWriting
    private let ledger: ScreenshotLedger
    private let edits: EditSession
    /// Reads a file's screenshot marker (its extended attributes); tests count the calls.
    private let readMarker: @Sendable (URL) -> Bool
    /// Whose files are read, and how large they may be (`FileTrust`); tests pass others.
    private let trust: FileTrust.Policy
    /// Sleeps until a rescan is due; tests release rescans by hand.
    private let sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void
    private let clock: @Sendable () -> Date
    private let pollInterval: Duration
    private let desktop: URL
    private let log: Log
    private let io = DispatchQueue(label: "sk.moravcik.ClipShot.copy-io", qos: .userInitiated)

    private var running = false
    private var generation = 0
    /// How many times `stop()` ran, readable on the `io` queue: a prefs read queued before a
    /// `stop()` but reached after it is skipped there, not only discarded on the way back.
    private let stops = StopCount()
    /// The folder the prefs named at the last re-target.
    private var configured: URL?
    /// Device and inode of the watched configured folder, to notice it being replaced.
    private var watchedIdentity: FolderIdentity?
    private var decider = CopyDecider()
    /// Files listed when the current folder was first watched; never recorded in the ledger.
    private var baseline: Set<FileKey> = []
    /// Every file version in the last listing (the re-target's or a pass's). A pass reads
    /// the marker of a file only when it could be copied: fresh by its times, open in
    /// Markup, or not in this set (P1: a folder of thousands of old screenshots costs one
    /// `lstat` each per pass, not four or five `getxattr`).
    private var known: Set<ListingKey> = []
    /// Hidden files seen while fresh: a capture macOS renames into place late is still copied.
    private var staged = StagedCaptures()
    /// Passes and polls finished; tests wait on them instead of sleeping.
    private(set) var passesFinished = 0
    private(set) var pollsFinished = 0
    /// Folder events handled since `start()`.
    private(set) var eventsHandled = 0

    /// No pass running or queued and no rescan left: what a test waits for before it says
    /// that nothing happened.
    var isIdle: Bool { !passInFlight && !passQueued && !seeding && rescanDeadlines.isEmpty && rescanTask == nil }
    /// No prefs read running or queued (the folder refresh of `start()` and the poll).
    var refreshIdle: Bool { !refreshInFlight && !refreshQueued }
    /// Fresh screenshots already sent to the ledger, with the time they were sent.
    private var recorded: [FileKey: Date] = [:]
    /// Versions of files open in Markup already sent to `followEdit`, with the time.
    private var followed: [FileKey: Date] = [:]
    /// The last ledger write, each chained after the one before, so they land in order and
    /// `ledgerSettled()` can wait for all of them.
    private var ledgerTail: Task<Void, Never>?

    private var seeding = false
    private var passInFlight = false
    private var passQueued = false
    /// A queued pass was asked for by a folder event or a rescan, not only by the poll.
    private var queuedForEvent = false
    private var refreshInFlight = false
    private var refreshQueued = false
    private var rescanDeadlines: [ContinuousClock.Instant] = []
    private var rescanTask: Task<Void, Never>?
    private var rescanToken = 0
    private var pollTask: Task<Void, Never>?

    init(
        settings: CaptureSettings, events: any FolderEventSource, pasteboard: any PasteboardWriting,
        ledger: ScreenshotLedger, edits: EditSession = EditSession(), clock: @escaping @Sendable () -> Date,
        pollInterval: Duration = .seconds(1),
        home: URL = FileManager.default.homeDirectoryForCurrentUser, log: Log = .shared,
        sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .continuous)
        },
        readMarker: @escaping @Sendable (URL) -> Bool = { CaptureMarker.isScreenshot($0) },
        trust: FileTrust.Policy = .standard
    ) {
        self.sleepUntil = sleepUntil
        self.readMarker = readMarker
        self.trust = trust
        self.settings = settings
        self.events = events
        self.pasteboard = pasteboard
        self.ledger = ledger
        self.edits = edits
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
                try? await Task.sleep(for: pollInterval, tolerance: pollInterval * Self.pollTolerance)
                guard !Task.isCancelled, let self else { return }
                // Only the folder pref and the folder itself are re-read every second (a new
                // ⇧⌘5 folder is picked up at once); a pass runs on the poll only while a
                // file is open in Markup, which may save in place and fire no folder event.
                self.requestRefresh()
                self.pruneMemory()
                if self.edits.isActive { self.requestPass(fromPoll: true) }
                self.pollsFinished += 1
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1
        stops.increment()
        pollTask?.cancel()
        pollTask = nil
        cancelRescans()
        seeding = false
        passQueued = false
        queuedForEvent = false
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
        let stops = stops
        let stopsNow = stops.value
        let probe = await onIO { () -> Probe? in
            // Stopped while this waited behind other IO: no prefs read after `stop()`.
            guard stops.value == stopsNow else { return nil }
            let folder = settings.folder()
            // A stop() that landed during the read: drop it here too, so nothing derived from a
            // read that straddled the stop (not even the folder probe) runs after it.
            guard stops.value == stopsNow else { return nil }
            let state = FolderState.of(folder)
            // ~/Desktop is only touched when it is needed as the fallback.
            guard case .missing = state else { return Probe(configured: folder, state: state, desktop: nil) }
            return Probe(configured: folder, state: state, desktop: .of(desktop))
        }
        guard let probe, running, gen == generation else { return }
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
        queuedForEvent = false
        seeding = true
        configured = plan.configured
        let events = events
        let onEvent = Self.eventHandler(for: self, generation: gen)
        let owner = trust.owner
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
            // Listed after the watch is up, so nothing lands between the two unseen. The seed
            // needs no markers: what is already there is never copied.
            return Retarget(
                watched: target, identity: FolderState.of(target).identity, error: plan.error,
                files: Self.list(target, owner: owner)?.files ?? [])
        }
        guard running, gen == generation else { return }
        seeding = false
        watchedFolder = result.watched
        watchedIdentity = result.identity
        if result.error != watchError { logWatchState(result) }
        watchError = result.error
        decider.seed(result.files, now: clock())
        baseline = Set(result.files.map(FileKey.init))
        known = Set(result.files.map(ListingKey.init))
        staged = StagedCaptures()
        recorded = [:]
        requestQueuedPass()
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
        eventsHandled += 1
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
                try await sleepUntil(next)
            } catch {
                return
            }
            let now = max(ContinuousClock.now, next)
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
    /// `fromPoll`: the poll asked for it while a file is open in Markup. Such a pass is never
    /// the last rescan, so a save that is still being written is retried, not a failure.
    private func requestPass(fromPoll: Bool = false) {
        guard running else { return }
        if seeding || passInFlight {
            passQueued = true
            if !fromPoll { queuedForEvent = true }
            return
        }
        guard let folder = watchedFolder else { return }
        passInFlight = true
        let gen = generation
        let decider = decider
        let copying = isEnabled
        // No rescan left after this one: a screenshot that still does not decode has failed.
        let lastRescan = !fromPoll && rescanDeadlines.isEmpty
        let clock = clock
        let edits = edits
        let known = known
        let staged = staged
        let readMarker = readMarker
        let trust = trust
        Task {
            let outcome = await onIO {
                Self.scan(
                    folder, decider: decider, edits: edits, known: known, staged: staged, readMarker: readMarker,
                    trust: trust, copying: copying, lastRescan: lastRescan, now: clock())
            }
            passInFlight = false
            if running, gen == generation {
                finishPass(outcome, copying: copying, lastRescan: lastRescan)
            }
            passesFinished += 1
            requestQueuedPass()
        }
    }

    private func requestQueuedPass() {
        guard passQueued else { return }
        passQueued = false
        let fromPoll = !queuedForEvent
        queuedForEvent = false
        requestPass(fromPoll: fromPoll)
    }

    private func finishPass(_ outcome: PassOutcome, copying: Bool, lastRescan: Bool) {
        guard case .listed(let listing) = outcome else {
            // The folder could not be listed: find out whether it is gone or locked.
            requestRefresh()
            return
        }
        known = listing.keys
        let observations = listing.observations
        if listing.foreign > 0 {
            // A shared folder: another user's file is never read, copied or recorded.
            let count = listing.foreign
            let log = log
            Task { await log.info("skipped \(count) new files not owned by this user") }
        }
        let now = clock()
        let copying = copying && isEnabled
        for temporary in listing.temporary { staged.saw(temporary, now: now) }
        for observation in observations {
            let file = observation.file
            let key = FileKey(file)
            let hidden = observation.hiddenFor
            if hidden > 0 { staged.appeared(file, hiddenFor: hidden) }
            if file.isScreenshot, CopyDecider.isFresh(file, now: now, hiddenFor: hidden),
               !baseline.contains(key), recorded[key] == nil {
                recorded[key] = now
                writeLedger { await $0.record(file) }
            }
            if observation.editing, followed[key] == nil {
                // Saved by replacing the file while it is open in Markup: keep it tracked.
                followed[key] = now
                writeLedger { await $0.followEdit(file) }
            }
            guard copying else {
                // While disabled, everything seen counts as handled: no catch-up on re-enable.
                decider.seed([file], now: now)
                continue
            }
            let editing = observation.editing
            guard decider.wouldCopy(file, now: now, hiddenFor: hidden, editing: editing) else {
                if observation.isNew, file.isScreenshot, !editing,
                   !CopyDecider.isFresh(file, now: now, hiddenFor: hidden) {
                    // Put back from the Trash, moved in, or written long before it appeared.
                    let age = Int(now.timeIntervalSince(file.created) - hidden)
                    let ext = file.url.pathExtension.lowercased()
                    let log = log
                    Task { await log.info("not copied, created \(age) s before it appeared ext=\(ext)") }
                }
                continue
            }
            // Waiting for an earlier file of the same capture to get its marker.
            if observation.deferred { continue }
            if observation.secondaryDisplay {
                _ = decider.shouldCopy(file, now: now, hiddenFor: hidden)
                onExtraDisplay?(file)
                continue
            }
            if let refusal = observation.refusal {
                // Refused by FileTrust (another user's, a symlink swapped in, too large):
                // handled, quietly. Never retried, never reported as a failed copy.
                _ = decider.shouldCopy(file, now: now, hiddenFor: hidden, editing: editing)
                let ext = file.url.pathExtension.lowercased()
                let log = log
                Task { await log.info("not copied, \(refusal.rawValue) ext=\(ext)") }
                continue
            }
            guard let png = observation.png else {
                // Not decodable yet: the next rescan tries again; after the last one it failed.
                if observation.converted, lastRescan {
                    _ = decider.shouldCopy(file, now: now, hiddenFor: hidden, editing: editing)
                    reportFailure(file)
                }
                continue
            }
            _ = decider.shouldCopy(file, now: now, hiddenFor: hidden, editing: editing)
            if pasteboard.writePNG(png) {
                lastCopied = file
                onCopied?(file)
                let ext = file.url.pathExtension.lowercased()
                // How long after the file appeared it reached the clipboard (Addendum A).
                let message = if editing {
                    "copied edit ext=\(ext)"
                } else if hidden >= 1 {
                    "copied late ext=\(ext), macOS held it back \(Int(hidden)) s"
                } else {
                    "copied ext=\(ext) \(Int((now.timeIntervalSince(file.created) * 1_000).rounded())) ms after the file appeared"
                }
                let log = log
                Task { await log.info(message) }
            } else {
                reportFailure(file)
            }
        }
    }

    private func writeLedger(_ write: @escaping @Sendable (ScreenshotLedger) async -> Void) {
        let previous = ledgerTail
        let ledger = ledger
        ledgerTail = Task {
            await previous?.value
            await write(ledger)
        }
    }

    /// Returns once every ledger write the coordinator has started is done: a screenshot just
    /// copied is then in the ledger, so Move to Trash on it is not refused.
    func ledgerSettled() async {
        await ledgerTail?.value
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
        staged.prune(now: now)
        recorded = recorded.filter { now.timeIntervalSince($0.value) <= CopyDecider.memory }
        followed = followed.filter { now.timeIntervalSince($0.value) <= CopyDecider.memory }
    }

    // MARK: - Off-main work

    private func onIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let io = io
        return await withCheckedContinuation { continuation in
            io.async { continuation.resume(returning: work()) }
        }
    }

    /// Lists, inspects, applies the multi-display rule and converts what may be copied.
    /// Every file costs one `lstat`; the marker is read only for a file that could be copied
    /// or is new since the last listing (`known`).
    nonisolated static func scan(
        _ folder: URL, decider: CopyDecider, edits: EditSession, known: Set<ListingKey>, staged: StagedCaptures,
        readMarker: (URL) -> Bool, trust: FileTrust.Policy = .standard, copying: Bool, lastRescan: Bool, now: Date
    ) -> PassOutcome {
        guard let (files, temporary) = list(folder, owner: trust.owner) else { return .unreadable }
        // Asked once: while nothing is open in Markup, no file needs the per-file check.
        let editingAny = edits.isActive
        var keys = Set<ListingKey>(minimumCapacity: files.count)
        var foreign = 0
        // Candidates: files whose marker is read. The rest can do nothing in this pass but
        // be seeded while copying is paused, so they stay in listing order, after the
        // candidates, and cost no sort.
        var candidates: [FileObservation] = []
        var rest: [FileObservation] = []
        for listed in files {
            let key = ListingKey(listed)
            keys.insert(key)
            // A file being edited stands alone: it is never part of a multi-display group.
            let editing = editingAny && edits.isEditing(listed)
            let hidden = staged.hiddenFor(listed, now: now)
            let fresh = CopyDecider.isFresh(listed, now: now, hiddenFor: hidden)
            let new = !known.contains(key)
            guard fresh || editing || new else {
                rest.append(FileObservation(file: listed, editing: false, isDisplay: false))
                continue
            }
            if fresh, new, !listed.isOwnedByUser { foreign += 1 }
            let file = listed.readingMarker(readMarker)
            candidates.append(FileObservation(
                file: file, editing: editing,
                isDisplay: !editing && file.isScreenshot && CaptureMarker.captureType(of: file.url) == "display",
                hiddenFor: hidden, isNew: new))
        }
        var observations = candidates.sorted {
            ($0.file.created, $0.file.url.path) < ($1.file.created, $1.file.url.path)
        } + rest
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
                .filter {
                    !$0.file.isScreenshot && $0.file.isOwnedByUser
                        && CopyDecider.isFresh($0.file, now: now, hiddenFor: $0.hiddenFor)
                }
                .map(\.file.created)
            for index in observations.indices
            where observations[index].isDisplay && !observations[index].secondaryDisplay {
                let created = observations[index].file.created
                observations[index].deferred = unmarked.contains {
                    $0 <= created && created.timeIntervalSince($0) <= displayGroupWindow
                }
            }
        }
        guard copying else {
            return .listed(Listing(observations: observations, keys: keys, foreign: foreign, temporary: temporary))
        }
        for index in observations.indices
        where !observations[index].secondaryDisplay && !observations[index].deferred
            && decider.wouldCopy(
                observations[index].file, now: now, hiddenFor: observations[index].hiddenFor,
                editing: observations[index].editing) {
            observations[index].converted = true
            switch PNGConverter.convert(observations[index].file.url, policy: trust) {
            case .png(let png): observations[index].png = png
            case .refused(let refusal): observations[index].refusal = refusal
            case .failed: break
            }
        }
        return .listed(Listing(observations: observations, keys: keys, foreign: foreign, temporary: temporary))
    }

    /// Direct children: the images, and apart from them the dot-files (capture temp names,
    /// spike F4) for `StagedCaptures`; non-images are skipped. `stat` only: no marker is read
    /// here. nil when the folder cannot be listed.
    nonisolated private static func list(
        _ folder: URL, owner: uid_t
    ) -> (files: [CaptureFile], temporary: [CaptureFile])? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var files: [CaptureFile] = []
        var temporary: [CaptureFile] = []
        for name in names {
            let url = folder.appendingPathComponent(name, isDirectory: false)
            if name.hasPrefix(".") {
                if let file = CaptureFile.statTemporary(url, owner: owner) { temporary.append(file) }
            } else if let file = CaptureFile.stat(url, owner: owner) {
                files.append(file)
            }
        }
        return (files, temporary)
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

/// One file version as a pass lists it, by name (the folder is fixed for a listing).
struct ListingKey: Hashable, Sendable {
    let name: String
    let resourceID: Data
    let modified: Date

    init(_ file: CaptureFile) {
        name = file.url.lastPathComponent
        resourceID = file.resourceID
        modified = file.modified
    }
}

struct FileObservation: Sendable {
    let file: CaptureFile
    /// In an edit session: exempt from the copy window's birth-time rule.
    let editing: Bool
    let isDisplay: Bool
    /// How long the file sat under a hidden name before it appeared (`StagedCaptures`).
    let hiddenFor: TimeInterval
    /// Not in the previous listing: put there, renamed or rewritten since.
    let isNew: Bool
    /// A later display of a multi-display capture: recorded, never copied.
    var secondaryDisplay = false
    /// A display file waiting for an earlier, still unmarked file of the same capture.
    var deferred = false
    /// Conversion was attempted in this pass.
    var converted = false
    var png: Data?
    /// `FileTrust` refused the file: it is skipped, not retried and not reported.
    var refusal: FileTrust.Refusal?

    init(file: CaptureFile, editing: Bool, isDisplay: Bool, hiddenFor: TimeInterval = 0, isNew: Bool = false) {
        self.file = file
        self.editing = editing
        self.isDisplay = isDisplay
        self.hiddenFor = hiddenFor
        self.isNew = isNew
    }
}

struct Listing: Sendable {
    let observations: [FileObservation]
    /// Every file version listed, for the next pass's `known`.
    let keys: Set<ListingKey>
    /// Fresh files new in this listing that another user owns.
    let foreign: Int
    /// Hidden files listed, for `StagedCaptures`.
    let temporary: [CaptureFile]
}

enum PassOutcome: Sendable {
    case listed(Listing)
    case unreadable
}

/// A counter the main actor bumps and the `io` queue reads.
private final class StopCount: Sendable {
    private let state = Mutex(0)

    var value: Int { state.withLock { $0 } }

    func increment() { state.withLock { $0 += 1 } }
}
