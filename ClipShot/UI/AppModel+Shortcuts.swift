import Foundation

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

    var message: LocalizedStringResource {
        switch self {
        case .notSetUp: Copy.Shortcuts.notSetUp
        case .noScreenshots: Copy.Shortcuts.noScreenshots
        case .copyFailed: Copy.Failure.copyFailed
        case .retentionOff: Copy.Shortcuts.retentionOff
        case .retentionRefused(.notConfirmed): Copy.Shortcuts.retentionNotConfirmed
        case .retentionRefused: Copy.Summary.offForFolder
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

/// What Clean Up Old Screenshots Now did, or would do with Preview only.
struct CleanUpReport: Equatable, Sendable {
    let count: Int
    let bytes: Int64
    let previewOnly: Bool
}

/// The Shortcuts actions and the Focus filter, on the same paths as the popover and Settings
/// (Addendum C). Each action that changes something refuses until the welcome tour has been
/// completed; none of them opens a window.
extension AppModel {
    /// Shortcuts may act: the tour was completed and watching has started.
    var shortcutsReady: Bool { preferences.tourCompleted && isWatching }

    /// Copying is paused because a Focus paused it; the popover says so.
    var pausedByFocus: Bool { !preferences.copyEnabled && preferences.focusPause.pausedCopying }

    // MARK: Copy to clipboard switch

    /// The user's own Copy to clipboard switch: the popover, Settings, the tour and the Pause
    /// and Resume Copying actions. Setting it by hand ends a Focus's claim on the pause: a
    /// Focus that ends afterwards resumes nothing, and a Resume while the Focus is on wins
    /// until the Focus changes. Peg's pause and resume play from the switch's change.
    func setCopying(_ on: Bool) {
        if preferences.focusPause.pausedCopying { preferences.focusPause.pausedCopying = false }
        if preferences.copyEnabled != on { preferences.copyEnabled = on }
    }

    /// The Focus filter's report: a Focus that pauses copying is on (`pausing`), or none is.
    /// A Focus turning on pauses copying unless it is paused already (by hand: then the Focus
    /// leaves it alone and its end resumes nothing). The Focus turning off resumes copying only
    /// when the Focus paused it and the switch has not been set by hand since. The same report
    /// again changes nothing, so a Resume by hand during the Focus holds until it changes.
    func focusChanged(pausing: Bool) {
        var pause = preferences.focusPause
        defer { if preferences.focusPause != pause { preferences.focusPause = pause } }
        guard pausing != pause.focusOn else { return }
        pause.focusOn = pausing
        if pausing {
            guard preferences.copyEnabled else { return }
            pause.pausedCopying = true
            preferences.copyEnabled = false
        } else {
            guard pause.pausedCopying else { return }
            pause.pausedCopying = false
            if !preferences.copyEnabled { preferences.copyEnabled = true }
        }
    }

    // MARK: Actions

    /// Get Latest Screenshot (`count` 1) and Get Recent Screenshots: the newest screenshots
    /// the popover would list, newest first, each read through `FileTrust`. A file refused or
    /// gone since it was chosen is left out.
    func shortcutScreenshots(count: Int) async throws(ShortcutError) -> [ShortcutFile] {
        guard shortcutsReady else { throw .notSetUp }
        let files = await recentScreenshots(count: min(max(count, 1), Self.shortcutMaxCount))
        let read = await Task.detached(priority: .userInitiated) {
            files.compactMap { file -> ShortcutFile? in
                guard case .success(let data) = FileTrust.read(file.url) else { return nil }
                return ShortcutFile(
                    data: data, name: file.url.lastPathComponent, fileExtension: file.url.pathExtension.lowercased())
            }
        }.value
        guard !read.isEmpty else { throw .noScreenshots }
        return read
    }

    /// The most screenshots Get Recent Screenshots returns.
    static let shortcutMaxCount = 10

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

    /// The Focus filter's `perform`: refused, changing nothing, before the tour is completed.
    func shortcutFocusChanged(pausing: Bool) throws(ShortcutError) {
        guard shortcutsReady else { throw .notSetUp }
        focusChanged(pausing: pausing)
    }

    /// Clean Up Old Screenshots Now: retention's own run (ledger, folder guard, revalidation,
    /// Trash only, at most 500), or with `previewOnly` the count that run would move, moving
    /// nothing. Never turns retention on and never plays a Peg moment.
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
            return previewOnly
                ? CleanUpReport(count: scan.expired.count, bytes: scan.expiredBytes, previewOnly: true)
                : CleanUpReport(count: 0, bytes: 0, previewOnly: false)
        }
    }
}
