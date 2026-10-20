import Foundation
import Synchronization

/// Why a Shortcuts action did nothing, said in the user's language (Addendum C).
enum ShortcutError: Error, Equatable {
    /// The welcome tour has not been completed: ClipShot does not touch the folder, the
    /// clipboard or the switch before it has been.
    case notSetUp
    /// No screenshot ClipShot tracks exists in the watched folder.
    case noScreenshots
    /// The screenshot could not be read or the clipboard took nothing.
    case copyFailed
    /// Retention is off; Clean Up never turns it on.
    case retentionOff
    /// Retention is on but would not run on the current folder.
    case retentionRefused(Refusal)
    /// The retention settings changed while the cleanup ran, twice, so nothing was moved.
    case retentionChanged

    var message: LocalizedStringResource {
        switch self {
        case .notSetUp: Copy.Shortcuts.notSetUp
        case .noScreenshots: Copy.Shortcuts.noScreenshots
        case .copyFailed: Copy.Failure.copyFailed
        case .retentionOff: Copy.Shortcuts.retentionOff
        case .retentionRefused(.notConfirmed): Copy.Shortcuts.retentionNotConfirmed
        case .retentionRefused: Copy.Summary.offForFolder
        case .retentionChanged: Copy.Shortcuts.retentionChanged
        }
    }
}

/// A screenshot handed to Shortcuts: its bytes, read through `FileTrust`, with its name and
/// extension. The system gets the data, never a path into the folder.
struct ShortcutFile: Equatable, Sendable {
    let data: Data
    let name: String
    let fileExtension: String
}

/// What Get Latest Screenshot and Get Recent Screenshots hand over: the files, and whether
/// the size cap stopped the reading before `count` were read (`AppModel.shortcutMaxBytes`).
struct ShortcutScreenshots: Equatable, Sendable {
    let files: [ShortcutFile]
    let cutShort: Bool
}

/// Why the launch could not tell whether a pausing Focus is on: the read took too long.
struct FocusReadTimedOut: Error {}

/// What Clean Up Old Screenshots Now did, or would do with Preview only.
struct CleanUpReport: Equatable, Sendable {
    let count: Int
    let bytes: Int64
    let previewOnly: Bool
}

/// The Shortcuts actions and the Focus filter, on the same paths as the popover and Settings
/// (Addendum C). Each action refuses until the welcome tour has been completed; none of them
/// opens a window.
extension AppModel {
    /// Shortcuts may act: the tour was completed and watching has started.
    var shortcutsReady: Bool { preferences.tourCompleted && isWatching }

    /// Copying is paused because a Focus that is on paused it; the popover says so. Never
    /// while the launch has not yet found out whether a Focus is on, nor in the grace after
    /// the Focus ended.
    var pausedByFocus: Bool {
        focusStateKnown && !preferences.copyEnabled && preferences.focusPause == FocusPause(focusOn: true, pausedCopying: true)
    }

    // MARK: Copy to clipboard switch

    /// The user's own Copy to clipboard switch: the popover, Settings, the tour and the Pause
    /// and Resume Copying actions. Setting it by hand ends a Focus's claim on the pause: a
    /// Focus that ends afterwards resumes nothing, and a Resume while the Focus is on wins
    /// until the Focus changes. Peg's pause and resume play from the switch's change.
    func setCopying(_ on: Bool) {
        if preferences.focusPause.pausedCopying { preferences.focusPause.pausedCopying = false }
        if preferences.copyEnabled != on { preferences.copyEnabled = on }
    }

    // MARK: Focus

    /// How long the end of a Focus waits before it resumes copying: a switch straight from one
    /// pausing Focus to another reports the first one's end, then the next one, and copying
    /// stays paused through it, with no Peg moment.
    static let focusOffGrace: Duration = .seconds(1)
    /// How long the launch waits for the system to say whether a pausing Focus is on.
    static let focusReadTimeout: Duration = .seconds(5)

    /// The Focus filter's report: a Focus that pauses copying is on (`pausing`), or none is.
    /// A Focus turning on pauses copying unless it is paused already (by hand: then the Focus
    /// leaves it alone and its end resumes nothing). The Focus turning off resumes copying only
    /// when the Focus paused it and the switch has not been set by hand since, after
    /// `focusOffGrace` unless `immediately`. The same report again changes nothing, so a
    /// Resume by hand during the Focus holds until it changes.
    func focusChanged(pausing: Bool, immediately: Bool = false) {
        var pause = preferences.focusPause
        defer { if preferences.focusPause != pause { preferences.focusPause = pause } }
        guard pausing != pause.focusOn else { return }
        pause.focusOn = pausing
        if pausing {
            // Cancels the resume of a Focus that just ended: still paused, nothing plays.
            focusOffGeneration += 1
            guard preferences.copyEnabled else { return }
            pause.pausedCopying = true
            preferences.copyEnabled = false
        } else {
            guard pause.pausedCopying else { return }
            guard !immediately else {
                pause.pausedCopying = false
                if !preferences.copyEnabled { preferences.copyEnabled = true }
                return
            }
            let generation = focusOffGeneration
            let clock = timerClock
            let end = clock.now + Self.focusOffGrace
            Task { [weak self] in
                try? await clock.sleep(until: end)
                guard let self else { return }
                defer { self.focusGracesSettled += 1 }
                guard self.focusOffGeneration == generation else { return }
                self.resumeAfterFocus()
            }
        }
    }

    /// The grace after a Focus ended is over and no pausing Focus came: copying resumes, if
    /// that Focus still holds the pause.
    private func resumeAfterFocus() {
        var pause = preferences.focusPause
        guard !pause.focusOn, pause.pausedCopying else { return }
        pause.pausedCopying = false
        preferences.focusPause = pause
        if !preferences.copyEnabled { preferences.copyEnabled = true }
    }

    /// The Focus filter's `perform`. Before the tour is completed it is refused and changes
    /// nothing, but the report is kept and applied when the tour is done.
    func shortcutFocusChanged(pausing: Bool) throws(ShortcutError) {
        guard shortcutsReady else {
            focusDuringTour = pausing
            throw .notSetUp
        }
        focusChanged(pausing: pausing)
    }

    /// `finishOnboarding`: the last Focus report kept during the tour, if any, applies now.
    func applyFocusReportedDuringTour() {
        guard let pausing = focusDuringTour, shortcutsReady else { return }
        focusDuringTour = nil
        focusChanged(pausing: pausing, immediately: true)
    }

    /// At launch: asks the system once (`read`, the Focus filter's current value) whether a
    /// pausing Focus is on, so a Focus that began or ended while ClipShot was not running is
    /// applied, and logs the answer. When it cannot be told (the read failed or took longer
    /// than `timeout`), copying is not left paused on a guess: a pause the Focus made is
    /// lifted, a pause by hand stays, and the popover no longer says a Focus is on.
    func reconcileFocusAtLaunch(
        timeout: Duration = AppModel.focusReadTimeout, _ read: @escaping @Sendable () async throws -> Bool
    ) async {
        focusStateKnown = false
        defer { focusStateKnown = true }
        let result = await Self.readFocus(read, timeout: timeout)
        let log = log
        switch result {
        case .success(let pausing):
            Task { await log.info("focus at launch: \(pausing ? "a pausing Focus is on" : "no pausing Focus")") }
            guard shortcutsReady else {
                focusDuringTour = pausing
                return
            }
            focusChanged(pausing: pausing, immediately: true)
            // A Focus that ended within its grace just before ClipShot quit left the pause
            // behind (focusOn false, pausedCopying true): no Focus is on, so it is lifted. A
            // pause by hand cleared `pausedCopying` and stays.
            if !pausing { resumeAfterFocus() }
        case .failure(let error):
            let kind = String(describing: type(of: error))
            focusDuringTour = nil
            var pause = preferences.focusPause
            let resume = pause.pausedCopying && !preferences.copyEnabled
            pause = FocusPause()
            if preferences.focusPause != pause { preferences.focusPause = pause }
            if resume { preferences.copyEnabled = true }
            Task {
                await log.error("focus at launch unknown (\(kind)); \(resume ? "resumed the pause it made" : "nothing to resume")")
            }
        }
    }

    /// `read`, or a `FocusReadTimedOut` failure once `timeout` passes, whichever comes first.
    /// A read that never returns is left behind, not awaited.
    nonisolated static func readFocus(
        _ read: @escaping @Sendable () async throws -> Bool, timeout: Duration
    ) async -> Result<Bool, any Error> {
        let once = OnceBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Bool, any Error>, Never>) in
            let reader = Task {
                let result: Result<Bool, any Error>
                do { result = .success(try await read()) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() {
                    reader.cancel()
                    continuation.resume(returning: .failure(FocusReadTimedOut()))
                }
            }
        }
    }

    // MARK: Actions

    /// Get Latest Screenshot (`count` 1) and Get Recent Screenshots: the newest screenshots
    /// the popover would list, newest first, each read through `FileTrust`. A file refused or
    /// gone since it was chosen is skipped and the next newest taken instead. The reading
    /// stops before the files read would pass `shortcutMaxBytes` (`cutShort`).
    func shortcutScreenshots(
        count: Int, maxBytes: Int = AppModel.shortcutMaxBytes
    ) async throws(ShortcutError) -> ShortcutScreenshots {
        guard shortcutsReady else { throw .notSetUp }
        let wanted = min(max(count, 1), Self.shortcutMaxCount)
        let candidates = await recentScreenshots(count: Self.shortcutMaxCount)
        let result = await Task.detached(priority: .userInitiated) { () -> ShortcutScreenshots in
            var read: [ShortcutFile] = []
            var total = 0
            for file in candidates where read.count < wanted {
                guard case .success(let data) = FileTrust.read(file.url) else { continue }
                if !read.isEmpty, total + data.count > maxBytes {
                    return ShortcutScreenshots(files: read, cutShort: true)
                }
                total += data.count
                read.append(ShortcutFile(
                    data: data, name: file.url.lastPathComponent, fileExtension: file.url.pathExtension.lowercased()))
            }
            return ShortcutScreenshots(files: read, cutShort: false)
        }.value
        guard !result.files.isEmpty else { throw .noScreenshots }
        return result
    }

    /// The most screenshots Get Recent Screenshots returns.
    static let shortcutMaxCount = 10
    /// The most bytes Get Recent Screenshots hands over at once; each file is at most
    /// `FileTrust`'s 256 MB, so the first one always fits.
    nonisolated static let shortcutMaxBytes = 512 * 1_024 * 1_024

    /// Copy Latest Screenshot: the popover's Copy on its top row.
    func shortcutCopyLatest() async throws(ShortcutError) {
        guard shortcutsReady else { throw .notSetUp }
        guard let file = await recentScreenshots(count: 1).first else { throw .noScreenshots }
        guard await copyExplicitly(file) else { throw .copyFailed }
    }

    /// Pause Copying and Resume Copying: the popover's switch.
    func shortcutSetCopying(_ on: Bool) throws(ShortcutError) {
        guard shortcutsReady else { throw .notSetUp }
        setCopying(on)
    }

    /// Clean Up Old Screenshots Now: retention's own run (ledger, folder guard, revalidation,
    /// Trash only, at most 500), or with `previewOnly` the count that run would move, moving
    /// nothing. Never turns retention on and never plays a Peg moment. Reports what the run
    /// really moved; a run dropped because the settings changed meanwhile is tried once more.
    func shortcutCleanUp(previewOnly: Bool) async throws(ShortcutError) -> CleanUpReport {
        guard shortcutsReady else { throw .notSetUp }
        guard preferences.retention.enabled else { throw .retentionOff }
        if !previewOnly, let result = await cleanUpNow() {
            return CleanUpReport(count: result.moved, bytes: result.movedBytes, previewOnly: false)
        }
        // Preview only, or a run that did not happen: the scan says what would move, or why
        // nothing would.
        switch await retentionScanNow() {
        case .failure(let refusal):
            throw .retentionRefused(refusal)
        case .success(let scan):
            guard preferences.retention.enabled else { throw .retentionOff }
            if previewOnly {
                return CleanUpReport(count: scan.expired.count, bytes: scan.expiredBytes, previewOnly: true)
            }
            guard !scan.expired.isEmpty else { return CleanUpReport(count: 0, bytes: 0, previewOnly: false) }
            // Something was due but no run happened: the policy changed while it scanned.
            guard let result = await cleanUpNow() else { throw .retentionChanged }
            return CleanUpReport(count: result.moved, bytes: result.movedBytes, previewOnly: false)
        }
    }
}

/// True for the first `claim()` only.
private final class OnceBox: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
