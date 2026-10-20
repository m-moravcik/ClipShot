import Accessibility
import AppKit
import Combine
import Observation

/// What the popover, Settings and onboarding bind to.
///
/// Inert until `startWatching()`: creating it reads no screenshot prefs, touches no folder,
/// pasteboard, timer or login item. Onboarding step 2 calls `startWatching()`, or `launch()`
/// does at app start once onboarding has been shown.
@MainActor
@Observable
final class AppModel {
    static let markupTipAfterCopies = 3
    static let previewDebounce: Duration = .milliseconds(300)
    /// How late the status loop may wake, so macOS can coalesce it with other wake-ups.
    static let statusTolerance = 0.2
    nonisolated static let defaultUndoLifetime: Duration = .seconds(5)

    let preferences: Preferences

    private(set) var isWatching = false
    /// The frame of Peg's moment playing in the menu bar; 0 when none plays.
    private(set) var flashPhase = 0
    /// The moment `flashPhase` belongs to.
    private(set) var flashMoment: PegMoment = .copied
    /// The state the icon rested in when the moment started.
    private(set) var flashFrom: StatusIconState = .idle
    /// Reduce Motion as read when the current flash started.
    private(set) var flashReduceMotion = false
    /// The pose on show when the current moment replaced one still playing, which it starts
    /// from; nil when it started at rest.
    private(set) var flashHandoff: Peg.Pose?
    private(set) var attentions: [Attention] = []
    /// Goes up once each time a problem appears that was not there before; the popover's
    /// header nods on it.
    private(set) var attentionArrivals = 0
    private(set) var lastCopied: CaptureFile?
    /// The folder being watched: the configured one, ~/Desktop while it is missing, or nil.
    private(set) var watchedFolder: URL?
    /// The folder the screenshot prefs name; nil until first read after `startWatching()`.
    private(set) var configuredFolder: URL?
    private(set) var destination: CaptureDestination = .file
    /// What retention would move now if it were on for the current folder.
    private(set) var retentionPreview: Result<RetentionScan, Refusal>?
    /// Why retention, while on, does not run on the current folder; nil when it runs or is off.
    private(set) var retentionRefusal: Refusal?
    /// `show-thumbnail`, as last read; nil until the first read after watching starts, so
    /// nothing decides on a value ClipShot has not seen.
    private(set) var showThumbnail: Bool?
    /// The tour's Start copying is writing the default Preview mode.
    private var applyingPreviewMode = false
    /// The `type` key, lowercased, as last read.
    private(set) var captureFormat = "png"
    /// A native setting was written while `screencaptureui` was running, so it applies from
    /// the next screenshot (spike F10). Cleared once that process has exited.
    private(set) var appliesFromNextScreenshot = false
    /// Why the last folder change was refused; nil after a successful one.
    private(set) var folderError: FolderValidation?
    /// The last Preview or destination change wrote nothing because the one-time backup of
    /// the macOS settings failed (C-2). Cleared by the next write that succeeds.
    private(set) var settingsBackupFailed = false
    /// The popover's list of recent screenshots (Task 12i): the current one on top, then the
    /// ones before it, newest first, at most `RecentScreenshots.count`, existing files only.
    /// Changes once the thumbnails are decoded (or failed to), so rows never flash empty.
    private(set) var recent: [CaptureFile] = []
    /// The list as the popover shows it: the rows, with the Undo strip in the place of the
    /// screenshot just moved to the Trash while its Undo is offered (Task 12i fix 1).
    var recentSlots: [RecentSlot] {
        RecentScreenshots.slots(files: recent, trashed: undoable?.file, wasListed: undoable?.listed ?? false)
    }
    /// Decoded thumbnails of the listed screenshots, so a popover that opens, or a row that
    /// moves up, never waits for a decode.
    private(set) var thumbnails: [CaptureFile: CGImage] = [:]
    /// The screenshot just moved to the Trash while its Undo is offered (Addendum A6). One at
    /// a time: a newer trash replaces it.
    private(set) var undoable: TrashedScreenshot?
    /// A Copy, Move to Trash or Undo from the popover that failed, said in a note above the
    /// list for `undoLifetime` (Addendum A6). One at a time.
    private(set) var actionNote: ActionNote?
    /// ClipShot's floating previews (Addendum A2); only filled in Preview mode ClipShot.
    let previews: FloatingPreviews

    /// The Preview mode in effect: what the user chose, overridden by the system's
    /// `show-thumbnail` (Addendum A1).
    var previewMode: PreviewMode {
        // Before the first read, and while the tour applies the default, the choice is what
        // applies.
        guard !applyingPreviewMode, let showThumbnail else { return preferences.previewMode }
        return .effective(stored: preferences.previewMode, showThumbnail: showThumbnail)
    }

    /// `show-thumbnail` has been read: only then does ClipShot show its preview or the macOS
    /// mode's rows.
    var previewModeKnown: Bool { showThumbnail != nil && !applyingPreviewMode }

    /// An install from before Preview modes, with the macOS thumbnail on: a one-time offer to
    /// copy at once. ClipShot never turns the thumbnail off on its own.
    var showsPreviewOffer: Bool {
        isWatching && previewModeKnown && !preferences.previewModeApplied && previewMode == .macOS
    }

    /// Preview mode macOS, after the offer: the header's status row says copying waits.
    var showsThumbnailWait: Bool {
        isWatching && previewModeKnown && previewMode == .macOS && !showsPreviewOffer
    }

    /// Paused until watching starts (the tour's Start copying, or a launch after the tour):
    /// nothing is copied before then, so the icon and its VoiceOver label do not say it is.
    ///
    /// A copy says Copied while its animation plays, also over an attention (the copy did
    /// happen); everything else is the state the icon rests in.
    var iconState: StatusIconState {
        .resolve(copyEnabled: preferences.copyEnabled && isWatching, attentions: attentions,
                 flashing: flashPhase > 0 && flashMoment == .copied)
    }

    /// The state the icon settles in once nothing plays.
    var restingIconState: StatusIconState {
        .resolve(copyEnabled: preferences.copyEnabled && isWatching, attentions: attentions, flashing: false)
    }

    /// What the menu bar draws now: the resting pose, or the frame of the moment playing.
    var iconPose: Peg.Pose { iconPose(rest: restingIconState) }

    /// What the menu bar draws with `rest` as the resting state: before a change of state is
    /// applied, the pose still on show.
    private func iconPose(rest: StatusIconState) -> Peg.Pose {
        Peg.pose(rest: rest, moment: flashPhase > 0 ? flashMoment : nil, phase: flashPhase,
                 from: flashFrom, reduceMotion: flashReduceMotion, handoff: flashHandoff)
    }

    /// The popover header: copying on, paused or needs attention. Never the brief copied state.
    var headerState: StatusIconState {
        .resolve(copyEnabled: preferences.copyEnabled, attentions: attentions, flashing: false)
    }

    /// macOS saves no file for a PDF capture while the floating thumbnail is on (spike F2).
    var pdfSavesNoFile: Bool { showThumbnail == true && captureFormat == "pdf" }

    /// Where screenshots are going right now: the watched folder, else the configured one.
    var screenshotFolder: URL? { watchedFolder ?? configuredFolder }

    /// `url` for display, with this model's home folder written as "~".
    func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = home.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The one-time Markup tip, from the third copy until dismissed.
    var showMarkupTip: Bool {
        !preferences.markupTipShown && preferences.totals.copied >= Self.markupTipAfterCopies
    }

    /// What Settings shows: the stored choice, off until there is one. Mid-tour nothing is
    /// registered yet, so it says off, as it is.
    var launchAtLogin: Bool { preferences.launchAtLoginIntent ?? false }

    /// What the tour's switch shows: the stored choice, else the tour's default (on), which
    /// leaving step 3 registers.
    var tourLaunchAtLogin: Bool { preferences.launchAtLoginIntent ?? LoginItem.tourDefault }

    // MARK: - Collaborators

    @ObservationIgnored private let settings: CaptureSettings
    @ObservationIgnored private let screencapturePrefs: any ScreencapturePreferences
    @ObservationIgnored private let backup: PrefsBackup
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let ledger: ScreenshotLedger
    @ObservationIgnored private let hasTrash: FolderGuard.TrashLookup
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let statusInterval: Duration
    @ObservationIgnored private let makeFlashTimer: AppDependencies.MakeFlashTimer
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored private let announce: @MainActor (LocalizedStringResource) -> Void
    @ObservationIgnored private let alert: @MainActor () -> Void
    @ObservationIgnored let workspace: any WorkspaceActions
    @ObservationIgnored private let screencaptureUIRunning: @MainActor () -> Bool
    @ObservationIgnored private let reconcileLoginItem: @MainActor (Bool?) -> Bool
    @ObservationIgnored private let setLoginItem: @MainActor (Bool) -> Bool
    @ObservationIgnored let log: Log
    @ObservationIgnored private let logFile: URL
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let osVersion: String
    @ObservationIgnored private let coordinator: CopyCoordinator
    @ObservationIgnored let edits: EditSession
    @ObservationIgnored private let trasher: any Trashing
    @ObservationIgnored private let undoLifetime: Duration
    @ObservationIgnored let timerClock: any TimerClock
    @ObservationIgnored private let locateTrash: AppDependencies.LocateTrash
    @ObservationIgnored private let makePreviewHost: @MainActor (AppModel) -> AnyObject?
    @ObservationIgnored let openMarkup: @MainActor (URL, @escaping @MainActor (MarkupResult) -> Void) -> Void
    @ObservationIgnored private let pass: RetentionPass
    @ObservationIgnored private let scheduler: RetentionScheduler

    // MARK: - Internal state

    @ObservationIgnored private var watchError: WatchError?
    @ObservationIgnored private var copyFailure: Date?
    /// The screenshot that could not be copied; "Copy again" retries it.
    @ObservationIgnored private var failedCapture: CaptureFile?
    /// The latest retention run, also when it moved nothing, for "Clean up now".
    @ObservationIgnored private var lastRun: RetentionResult?
    @ObservationIgnored private var runCount = 0
    /// Names the latest `refreshRecent()`, so an older one that finishes later is dropped.
    @ObservationIgnored private var recentGeneration = 0
    /// The generation of the last refresh that was shown.
    @ObservationIgnored private var recentShown = 0
    /// Status reads finished since watching started; tests wait on it.
    @ObservationIgnored private(set) var statusReads = 0
    /// Thumbnail decodes in flight, so overlapping refreshes share them.
    @ObservationIgnored private var decoding: [CaptureFile: Task<CGImage?, Never>] = [:]
    /// Files on show whose thumbnail could not be decoded; not tried again. Keyed by the file's
    /// version: `CaptureFile` equality covers the resource ID, size and modification date, so
    /// a file that was still being written is decoded again once it changes.
    @ObservationIgnored private var undecodable: Set<CaptureFile> = []
    /// Names the Undo on offer, so the timer of a replaced one does not end the newer one.
    @ObservationIgnored private var undoGeneration = 0
    /// An Undo is putting its file back: a second one waits for nothing and fails.
    @ObservationIgnored private var restoring = false
    /// Names the note on show, so the timer of a replaced one does not end the newer one.
    @ObservationIgnored private var noteGeneration = 0
    @ObservationIgnored private var flash = PegFlash()
    @ObservationIgnored private var flashTimer: (any FlashTimer)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The popover is on screen. Its window stays alive while closed, so only then does the
    /// status loop re-read the recent screenshots (P2).
    @ObservationIgnored private(set) var popoverVisible = false
    @ObservationIgnored private var statusInFlight = false
    @ObservationIgnored private var statusQueued = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var observationToken = 0
    @ObservationIgnored private var observedPolicy: RetentionPolicy?
    /// The Copy to clipboard switch as last seen, so only a real flip plays pause or resume.
    @ObservationIgnored private var observedCopyEnabled = true
    /// Names the resume a Focus that ended has scheduled, so a pausing Focus reported within
    /// `focusOffGrace` (a switch straight to another one) cancels it (Shortcuts).
    @ObservationIgnored var focusOffGeneration = 0
    /// Grace periods after a Focus ended that have run out, resumed or not; tests wait on it.
    @ObservationIgnored var focusGracesSettled = 0
    /// The Focus filter's last report while the tour was not completed yet; applied when it is.
    @ObservationIgnored var focusDuringTour: Bool?
    /// False while the launch reads whether a pausing Focus is on: until then the popover does
    /// not say a Focus paused copying.
    var focusStateKnown = true
    /// The panel that shows `previews`, made when watching first starts.
    @ObservationIgnored private var previewHost: AnyObject?
    /// The pasteboard's change count right after ClipShot's last write: when it differs, the
    /// clipboard holds something else and the preview offers Copy again.
    @ObservationIgnored private var changeCountAfterCopy: Int?

    init(dependencies d: AppDependencies) {
        preferences = d.preferences
        screencapturePrefs = d.screencapturePrefs
        backup = d.backup
        home = d.home
        pasteboard = d.pasteboard
        ledger = d.ledger
        hasTrash = d.hasTrash
        clock = d.clock
        statusInterval = d.statusInterval
        makeFlashTimer = d.makeFlashTimer
        reduceMotion = d.reduceMotion
        announce = d.announce
        alert = d.alert
        workspace = d.workspace
        screencaptureUIRunning = d.screencaptureUIRunning
        reconcileLoginItem = d.reconcileLoginItem
        setLoginItem = d.setLoginItem
        log = d.log
        logFile = d.logFile
        appVersion = d.appVersion
        osVersion = d.osVersion
        edits = d.edits
        trasher = d.trasher
        makePreviewHost = d.makePreviewHost
        openMarkup = d.openMarkup
        undoLifetime = d.undoLifetime
        timerClock = d.timerClock
        locateTrash = d.locateTrash
        previews = FloatingPreviews(lifetime: d.previewLifetime, clock: d.timerClock)
        let settings = CaptureSettings(prefs: d.screencapturePrefs, home: d.home, backup: d.backup, log: d.log)
        self.settings = settings
        coordinator = CopyCoordinator(
            settings: settings, events: d.events, pasteboard: d.pasteboard, ledger: d.ledger,
            edits: d.edits, clock: d.clock, pollInterval: d.pollInterval, home: d.home, log: d.log)
        pass = RetentionPass(
            settings: settings, ledger: d.ledger,
            runner: RetentionRunner(trasher: d.trasher, ledger: d.ledger, home: d.home, log: d.log),
            home: d.home, hasTrash: d.hasTrash)
        scheduler = RetentionScheduler(hourly: d.hourly, wake: d.wake)

        coordinator.onStateChange = { [weak self] in self?.coordinatorChanged() }
        coordinator.onCopied = { [weak self] in self?.copied($0) }
        coordinator.onFailure = { [weak self] in self?.copyFailed($0) }
        coordinator.onExtraDisplay = { [weak self] in self?.extraDisplay($0) }
        scheduler.work = { [weak self] in await self?.runRetention() }
    }

    /// Stops what `startWatching()` started when the model goes away without `stopWatching()`.
    isolated deinit {
        coordinator.stop()
        scheduler.stop()
        statusTask?.cancel()
        previewTask?.cancel()
        flashTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// At app start: resumes watching once the welcome tour has been completed, even when a
    /// replay of it now waits in the popover (a replay is a request to show the tour again,
    /// not a reset of copying).
    func launch() {
        if preferences.tourCompleted { startWatching() }
    }

    /// The first moment ClipShot touches the screenshot folder, prefs, pasteboard and login item.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        if LoginItem.reconcilesAtStart(
            storedIntent: preferences.launchAtLoginIntent, tourCompleted: preferences.tourCompleted) {
            preferences.launchAtLoginIntent = reconcileLoginItem(preferences.launchAtLoginIntent)
        }
        observedPolicy = preferences.retention
        observedCopyEnabled = preferences.copyEnabled
        coordinator.isEnabled = preferences.copyEnabled
        coordinator.start()
        if previewHost == nil { previewHost = makePreviewHost(self) }
        observePreferences()
        statusTask = Task { [weak self, statusInterval] in
            while !Task.isCancelled {
                // Not held across the sleep, so a released model ends the loop.
                guard let model = self else { return }
                model.refreshStatus()
                model.forgetClipboardIfReplaced()
                // A screenshot deleted or renamed in Finder leaves the list; with the
                // popover closed, that waits until it opens.
                if model.popoverVisible { model.refreshRecent() }
                try? await Task.sleep(for: statusInterval, tolerance: statusInterval * Self.statusTolerance)
            }
        }
        scheduler.start()
    }

    /// The tour's Start copying: starts watching and, the first time, applies the default
    /// Preview mode (ClipShot: the macOS thumbnail goes off, through the backup). This is the
    /// user's choice, and the tour's Try it says what it means.
    func startCopying() {
        if !preferences.previewModeApplied {
            applyingPreviewMode = true
            startWatching()
            Task { await applyDefaultPreviewMode() }
        } else {
            startWatching()
        }
    }

    /// Done or Skip in the welcome tour: the only place that records it as shown. Watching
    /// starts too, as it would at the next launch. Launch at login, when the user has not
    /// chosen: registered when its switch was on screen (step 3, where it starts on),
    /// else the system's state is taken, as at any launch.
    func finishOnboarding(launchAtLoginShown: Bool = false) {
        startWatching()
        if preferences.launchAtLoginIntent == nil {
            if let intent = LoginItem.intentAtTourEnd(storedIntent: nil, switchShown: launchAtLoginShown) {
                setLaunchAtLogin(intent)
            } else {
                preferences.launchAtLoginIntent = reconcileLoginItem(nil)
            }
        }
        preferences.onboardingShown = true
        // A Focus reported while the tour ran applies now that it is done.
        applyFocusReportedDuringTour()
    }

    /// Settings > General: shows the welcome tour again the next time the popover opens.
    /// Copying goes on meanwhile, also after a relaunch (`tourCompleted` stays).
    func replayOnboarding() {
        preferences.onboardingShown = false
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        observationToken += 1
        coordinator.stop()
        scheduler.stop()
        statusTask?.cancel()
        statusTask = nil
        previewTask?.cancel()
        previewTask = nil
        flashTimer?.invalidate()
        flashTimer = nil
        flashPhase = 0
        previews.dismissAll()
        watchedFolder = nil
        watchError = nil
        recomputeAttentions()
    }

    // MARK: - Copy

    /// The popover opened or closed. Opening re-reads what it shows: a screenshot deleted in
    /// Finder meanwhile leaves the list, and Copy again moves off a screenshot that is no
    /// longer on the clipboard. Peg answers the click that opened it with a squeeze, as the
    /// popover appears (`freshOpen`: the window was ordered out before, so a click opened it,
    /// not an occlusion round trip); closing it plays nothing.
    func popoverVisibilityChanged(_ visible: Bool, freshOpen: Bool = true) {
        guard visible != popoverVisible else { return }
        popoverVisible = visible
        if visible {
            if freshOpen { play(.squeeze, from: restingIconState) }
            forgetClipboardIfReplaced()
            refreshRecent()
            refreshStatus()
        }
    }

    // Observed properties are only assigned when they change: every assignment notifies,
    // and the popover's window, alive while closed, would lay itself out again (P2).
    private func coordinatorChanged() {
        let copiedChanged = lastCopied != coordinator.lastCopied
        if copiedChanged { lastCopied = coordinator.lastCopied }
        watchError = coordinator.watchError
        let folderChanged = watchedFolder != coordinator.watchedFolder
        if folderChanged { watchedFolder = coordinator.watchedFolder }
        recomputeAttentions()
        if copiedChanged || folderChanged { refreshRecent() }
        if folderChanged {
            refreshStatus()
            if retentionPreview != nil { refreshPreview() }
        }
    }

    /// Where a clipboard write came from. Every write ClipShot makes, whatever started it,
    /// ends in `didWriteClipboard` (R-2): PNG data only, the menu bar's copy animation, the
    /// VoiceOver announcement, and one more in the copied total.
    ///
    /// Paused (Copy to clipboard off) stops what ClipShot does on its own: a new screenshot
    /// (`observed`) and an edited image Markup hands back (`edited`). An explicit Copy on the
    /// list of recent screenshots, the preview or an attention row (`again`) still works.
    enum CopyOrigin: Equatable {
        case observed(CaptureFile)
        case again(CaptureFile)
        case edited

        var isExplicit: Bool { if case .again = self { true } else { false } }
    }

    private func copied(_ file: CaptureFile) {
        didWriteClipboard(.observed(file))
    }

    /// Writes `png` for `origin`; false when paused (for what ClipShot does on its own) or
    /// when the pasteboard refused it.
    func writeClipboard(_ png: Data, _ origin: CopyOrigin) -> Bool {
        guard origin.isExplicit || preferences.copyEnabled, pasteboard.writePNG(png) else { return false }
        didWriteClipboard(origin)
        return true
    }

    private func didWriteClipboard(_ origin: CopyOrigin) {
        changeCountAfterCopy = pasteboard.changeCount
        preferences.totals.copied += 1
        switch origin {
        case .observed(let file), .again(let file): previews.clipboardFile = file
        case .edited: previews.clipboardFile = nil
        }
        switch origin {
        case .observed(let file):
            lastCopied = file
            refreshRecent()
            if previewModeKnown, previewMode.showsOwnPreview { showPreview(file) }
            clearCopyFailure()
        case .again(let file):
            if file == failedCapture { clearCopyFailure() }
        case .edited:
            break
        }
        startFlash()
        announce(Copy.screenshotCopied)
    }

    /// Decodes the preview image off the main actor (tens of ms), then shows it.
    private func showPreview(_ file: CaptureFile) {
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                Thumbnailer.decode(file.url, maxPixelSize: PreviewCardMetrics.imagePixels)
            }.value
            guard let self, self.isWatching, self.previewModeKnown, self.previewMode.showsOwnPreview else { return }
            self.previews.show(file, image: image)
        }
    }

    private func extraDisplay(_ file: CaptureFile) {
        guard previewModeKnown, previewMode.showsOwnPreview else { return }
        previews.addExtraDisplay(file)
    }

    // MARK: - Recent screenshots

    /// Re-reads which screenshots the list shows, and decodes the thumbnails it lacks, off
    /// the main actor. Then the list changes in one step. Called after a copy, a move to the
    /// Trash, an Undo, a cleanup, a folder change and when the popover opens.
    func refreshRecent() {
        recentGeneration += 1
        let generation = recentGeneration
        let lastCopied = lastCopied
        let folder = isWatching ? watchedFolder : nil
        let ledger = ledger
        let coordinator = coordinator
        Task { [weak self] in
            // A screenshot just copied is in the ledger before the list is chosen.
            await coordinator.ledgerSettled()
            let entries = folder == nil ? [] : await ledger.entries()
            let files = await Task.detached(priority: .utility) {
                RecentScreenshots.select(lastCopied: lastCopied, ledger: entries, folder: folder)
            }.value
            guard let self, generation == self.recentGeneration else { return }
            let images = await self.thumbnails(for: files)
            guard generation == self.recentGeneration else { return }
            self.show(files, images: images)
            self.recentShown = generation
        }
    }

    /// The newest `count` screenshots, newest first, chosen as the popover's list chooses them
    /// (existing files only, direct children of the watched folder), for Shortcuts. Waits for
    /// the folder on a launch that has just started watching, at most `folderWait`.
    func recentScreenshots(count: Int) async -> [CaptureFile] {
        guard isWatching, await watchedFolderSettled() != nil else { return [] }
        await coordinator.ledgerSettled()
        guard isWatching, let folder = watchedFolder else { return [] }
        let entries = await ledger.entries()
        let lastCopied = lastCopied
        return await Task.detached(priority: .userInitiated) {
            RecentScreenshots.select(lastCopied: lastCopied, ledger: entries, folder: folder, count: count)
        }.value
    }

    /// How long `recentScreenshots` waits for the coordinator to name the folder.
    static let folderWait: Duration = .seconds(2)

    /// The watched folder, waiting up to `folderWait` for the coordinator to name it after
    /// `startWatching()`: Shortcuts and `clipshot` may launch or reach ClipShot just to ask.
    func watchedFolderSettled() async -> URL? {
        let clock = ContinuousClock()
        let deadline = clock.now + Self.folderWait
        while isWatching, watchedFolder == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isWatching ? watchedFolder : nil
    }

    // MARK: - Test hooks
    //
    // Completion signals, so a test that says "nothing (else) happened" waits for the work it
    // is about instead of a fixed sleep that may end first (R-9).

    /// The newest `refreshRecent()` has shown its result.
    var recentSettled: Bool { recentShown == recentGeneration }
    /// Folder events the copy pipeline has handled.
    var copyEventsHandled: Int { coordinator.eventsHandled }
    /// No copy pass running or queued, and no rescan left.
    var copyIdle: Bool { coordinator.isIdle }
    /// Whether the copy pipeline copies now (it follows the Copy to clipboard switch).
    var copyEnabledInPipeline: Bool { coordinator.isEnabled }

    /// The thumbnails of `files`: from the cache, or decoded off the main actor. A decode
    /// already running for a file (from an earlier refresh) is awaited, not repeated, and a
    /// file version that could not be decoded is not tried again while it is on show.
    private func thumbnails(for files: [CaptureFile]) async -> [CaptureFile: CGImage] {
        var pending: [(CaptureFile, Task<CGImage?, Never>)] = []
        var images: [CaptureFile: CGImage] = [:]
        for file in files {
            if let image = thumbnails[file] {
                images[file] = image
            } else if !undecodable.contains(file) {
                let task = decoding[file] ?? Task.detached(priority: .utility) {
                    Thumbnailer.decode(file.url, maxPixelSize: RecentRow.thumbnailPixels)
                }
                decoding[file] = task
                pending.append((file, task))
            }
        }
        for (file, task) in pending {
            let image = await task.value
            decoding[file] = nil
            // Kept at once, so a newer refresh that started meanwhile finds it.
            if let image {
                images[file] = image
                if thumbnails[file] == nil { thumbnails[file] = image }
            } else {
                undecodable.insert(file)
            }
        }
        return images
    }

    private func show(_ files: [CaptureFile], images: [CaptureFile: CGImage]) {
        // Only what is on show, plus the file an Undo may bring back.
        let keep = Set(files + [undoable?.file].compactMap { $0 })
        let cache = thumbnails.merging(images) { old, _ in old }.filter { keep.contains($0.key) }
        undecodable.formIntersection(keep)
        if cache != thumbnails { thumbnails = cache }
        if recent != files { recent = files }
    }

    /// `file` left the folder (moved to the Trash): its row leaves at once, before the folder
    /// is read again (the Undo strip takes its place while Undo is offered); that read brings
    /// the older screenshot that takes the last row once Undo is over.
    func screenshotLeft(_ file: CaptureFile) {
        let path = file.url.standardizedFileURL.path
        if recent.contains(where: { $0.url.standardizedFileURL.path == path }) {
            recent.removeAll { $0.url.standardizedFileURL.path == path }
        }
        refreshRecent()
    }

    /// `file` is the screenshot ClipShot last put on the clipboard, and it is still there:
    /// its row says Copy again, as only its floating preview says Copied (U9). The same
    /// comparison as the preview's (`FloatingPreviews.isOnClipboard`).
    func isOnClipboard(_ file: CaptureFile) -> Bool {
        previews.isOnClipboard(file)
    }

    /// Waits until the ledger has every screenshot the coordinator has seen so far.
    func ledgerSettled() async {
        await coordinator.ledgerSettled()
    }

    /// `file` is one the popover's list could hold: in the ledger (seen being taken, or
    /// adopted for cleanup) or the last copy, as the same file (resource identifier). Any
    /// other file, an image in the folder included, is not ClipShot's to copy.
    func isTracked(_ file: CaptureFile) async -> Bool {
        await coordinator.ledgerSettled()
        let path = FolderGuard.canonicalPath(file.url)
        if let lastCopied, lastCopied.resourceID == file.resourceID,
           FolderGuard.canonicalPath(lastCopied.url) == path {
            return true
        }
        return await ledger.contains(path: path, resourceID: file.resourceID)
    }

    private func copyFailed(_ file: CaptureFile) {
        copyFailure = clock()
        failedCapture = file
        recomputeAttentions()
        // It is listed all the same, on top, with Copy.
        refreshRecent()
    }

    private func clearCopyFailure() {
        guard copyFailure != nil || failedCapture != nil else { return }
        copyFailure = nil
        failedCapture = nil
        recomputeAttentions()
    }

    /// The menu bar's copy animation.
    func startFlash() {
        play(.copied, from: restingIconState)
    }

    /// Plays `moment` in the menu bar, from the state the icon rested in.
    ///
    /// Precedence (`PegMoment.replaces`): among copy, release and grip the latest wins; a
    /// change of state (attention, pause, resume) replaces anything but a copy and gives way to
    /// nothing below it; the squeeze replaces only a squeeze. A copy is never cut short by a
    /// change of state (it ends on the new resting card instead). A moment that may replace
    /// the one playing starts from the pose on show (`flashHandoff`), so nothing jumps; one
    /// that may not does not play.
    ///
    /// One timer at a time: a moment during another restarts the phases on the same frame
    /// timer. With Reduce Motion a copy, release or grip is one hold on a single timer, so
    /// anything during it starts on a fresh timer; the other moments do not play at all: their
    /// state changes in one frame, ending a lower hold so it shows at once.
    ///
    /// `shown`: the pose on show, when the state it was drawn with has changed already.
    private func play(_ moment: PegMoment, from: StatusIconState, shown: Peg.Pose? = nil) {
        let reduce = reduceMotion()
        let playing = flashPhase > 0 ? flashMoment : nil
        if let playing, !moment.replaces(playing) { return }
        guard !reduce || moment.reduceMotionHold != nil else {
            if playing != nil { endFlash() }
            return
        }
        let handoff = playing != nil && !reduce && !flashReduceMotion ? shown ?? iconPose : nil
        let next = PegFlash(moment, reduceMotion: reduce)
        if flashTimer != nil, flash.timerInterval != next.timerInterval || flash.reduceMotion {
            flashTimer?.invalidate()
            flashTimer = nil
        }
        flash = next
        flashReduceMotion = next.reduceMotion
        flashMoment = moment
        flashFrom = from
        flashHandoff = handoff
        if flashTimer == nil {
            flashTimer = makeFlashTimer(flash.timerInterval, PegFlash.tolerance) { [weak self] in
                self?.tickFlash()
            }
        }
        flash.restart()
        flashPhase = flash.tick()
    }

    private func tickFlash() {
        flashPhase = flash.tick()
        guard flashPhase == 0 else { return }
        flashTimer?.invalidate()
        flashTimer = nil
    }

    /// Stops the moment playing, and its timer, on the resting pose.
    private func endFlash() {
        flashTimer?.invalidate()
        flashTimer = nil
        flash = PegFlash()
        flashPhase = 0
    }

    /// Copies the screenshot that failed, or else the latest one, again.
    @discardableResult
    func copyAgain() async -> Bool {
        guard let file = failedCapture ?? lastCopied else { return false }
        return await copyAgain(file: file)
    }

    /// Copies `file` again: the screenshot of the row (or preview `preview`) whose Copy was
    /// clicked. The menu bar plays its copy animation, as for a new screenshot. An explicit
    /// Copy, so it works while copying is paused. Clears the could-not-copy attention only
    /// when `file` is the one that failed.
    ///
    /// A Copy that fails (the file is gone or refused, or the pasteboard took nothing) says
    /// so where the user acted, as a failed Move to Trash does: on the preview, or in the
    /// note above the popover's list, with the alert sound and VoiceOver.
    @discardableResult
    func copyAgain(file: CaptureFile, fromPreview preview: UUID? = nil) async -> Bool {
        guard await copyExplicitly(file) else {
            actionFailed(.copy, preview: preview)
            return false
        }
        if let preview { previews.clearFailure(on: preview) }
        return true
    }

    /// The user's own Copy of `file`, wherever it was asked for (a row, a preview, an attention
    /// row, Shortcuts): converted to PNG off the main actor, then through `writeClipboard` as
    /// `.again`, so it works while paused and counts, owns the clipboard and plays Peg's copy
    /// as any copy does. False, with nothing said, when it failed; the caller says it where
    /// the user asked.
    func copyExplicitly(_ file: CaptureFile) async -> Bool {
        let outcome = await Task.detached(priority: .userInitiated) { PNGConverter.convert(file.url) }.value
        let ext = file.url.pathExtension.lowercased()
        let log = log
        guard case .png(let png) = outcome, writeClipboard(png, .again(file)) else {
            if case .refused(let refusal) = outcome {
                Task { await log.info("copy again refused, \(refusal.rawValue) ext=\(ext)") }
            } else {
                Task { await log.error("copy again failed ext=\(ext)") }
            }
            return false
        }
        Task { await log.info("copied again ext=\(ext)") }
        return true
    }

    /// The page in System Settings where folder access is granted (spike F15).
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    func openPrivacySettings() {
        workspace.open(Self.privacySettingsURL)
    }

    /// Opens the Trash of the screenshot folder's volume, or the home Trash when that one
    /// cannot be found. False when no Trash could be opened, so Settings says so instead of
    /// doing nothing.
    @discardableResult
    func showTrash() async -> Bool {
        let folder = screenshotFolder ?? home
        let locate = locateTrash
        let trash = await Task.detached(priority: .userInitiated) { locate(folder) ?? locate(nil) }.value
        let log = log
        guard let trash else {
            Task { await log.error("show trash: no trash found") }
            return false
        }
        guard workspace.open(trash) else {
            Task { await log.error("show trash: open failed") }
            return false
        }
        return true
    }

    func openFolder() {
        guard let folder = screenshotFolder else { return }
        workspace.open(folder)
    }

    func dismissMarkupTip() {
        preferences.markupTipShown = true
    }

    /// Another app copied something since ClipShot's last write: no preview says Copied any
    /// more. Checked with the status loop, only while ClipShot claims the clipboard.
    func forgetClipboardIfReplaced() {
        guard previews.clipboardFile != nil, clipboardChangedSinceCopy else { return }
        previews.clipboardFile = nil
    }

    /// Something other than ClipShot's last copy is on the clipboard now.
    var clipboardChangedSinceCopy: Bool {
        guard let changeCountAfterCopy else { return true }
        return pasteboard.changeCount != changeCountAfterCopy
    }

    // MARK: - Native settings

    func fixDestination() async {
        let settings = settings
        let written = await Task.detached { settings.fixDestination() }.value
        settingsWritten(written)
        if written { nativeSettingChanged() }
    }

    private func settingsWritten(_ written: Bool) {
        if settingsBackupFailed != !written { settingsBackupFailed = !written }
    }

    /// The upgrade offer's Copy at once.
    func acceptPreviewOffer() async {
        await setPreviewMode(.clipShot)
    }

    /// The upgrade offer's close: never offered again.
    func dismissPreviewOffer() {
        preferences.previewModeApplied = true
    }

    /// Settings > Capture > Preview. Writes `show-thumbnail` through the backup-once path;
    /// the choice is kept only once that write succeeded, so the picker never shows a mode
    /// that is not in effect, and never flips back later on its own.
    func setPreviewMode(_ mode: PreviewMode) async {
        guard await writeShowThumbnail(mode.showsSystemThumbnail) else { return }
        preferences.previewMode = mode
        preferences.previewModeApplied = true
        if !mode.showsOwnPreview { previews.dismissAll() }
    }

    /// The tour's Start copying applies the chosen mode once (ClipShot by default, so the
    /// macOS thumbnail goes off and copies land at once). Afterwards the system pref is only
    /// read, never flipped back.
    private func applyDefaultPreviewMode() async {
        defer { applyingPreviewMode = false }
        guard !preferences.previewModeApplied else { return }
        let wanted = preferences.previewMode.showsSystemThumbnail
        let settings = settings
        let current = await Task.detached { settings.showThumbnail }.value
        if current != wanted {
            guard await writeShowThumbnail(wanted) else {
                // Nothing changed: the mode stays what the system has, and the one-time
                // offer stays for later.
                showThumbnail = current
                return
            }
            let log = log
            Task { await log.info("preview mode applied, thumbnail \(wanted ? "on" : "off")") }
        } else {
            showThumbnail = current
        }
        preferences.previewModeApplied = true
    }

    /// False when the backup failed and nothing was written; Settings > Capture says so.
    @discardableResult
    private func writeShowThumbnail(_ on: Bool) async -> Bool {
        let settings = settings
        let written = await Task.detached { settings.setShowThumbnail(on) }.value
        settingsWritten(written)
        guard written else { return false }
        if showThumbnail != on { showThumbnail = on }
        nativeSettingChanged()
        return true
    }

    func clearFolderError() {
        folderError = nil
    }

    /// After a write to `com.apple.screencapture`: a running `screencaptureui` keeps the old
    /// values until it exits, and ClipShot never kills it (spike F10).
    private func nativeSettingChanged() {
        if screencaptureUIRunning() { appliesFromNextScreenshot = true }
        refreshStatus()
    }

    func setFolder(_ url: URL) async throws(FolderValidation) {
        try await writeFolder(url)
    }

    func resetFolder() async throws(FolderValidation) {
        try await writeFolder(nil)
    }

    private func writeFolder(_ url: URL?) async throws(FolderValidation) {
        let settings = settings
        let result = await Task.detached { () -> Result<Void, FolderValidation> in
            do throws(FolderValidation) {
                try settings.setFolder(url)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        do throws(FolderValidation) {
            try result.get()
        } catch {
            folderError = error
            throw error
        }
        folderError = nil
        nativeSettingChanged()
    }

    @discardableResult
    func restorePreviousSettings() async -> Bool {
        let backup = backup
        let prefs = screencapturePrefs
        let restored = await Task.detached { backup.restore(into: prefs) }.value
        if restored { nativeSettingChanged() }
        return restored
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        preferences.launchAtLoginIntent = enabled
        return setLoginItem(enabled)
    }

    // MARK: - Retention

    /// Runs retention now (Settings "Clean up now"), after any run in flight. Returns what
    /// that run moved, or nil when nothing ran.
    @discardableResult
    func cleanUpNow() async -> RetentionResult? {
        guard isWatching else { return nil }
        let before = runCount
        await scheduler.runNow()
        return runCount != before ? lastRun : nil
    }

    /// Adds the older screenshots the preview counted (expired, never seen by ClipShot) to the
    /// ledger, after the user confirmed "Also clean up N older screenshots". Only those files,
    /// and only while they still qualify, so the count adopted never exceeds the count shown.
    /// They then go with the next run. Returns how many were adopted; 0 when there is no
    /// preview or the folder is no longer the one it showed.
    @discardableResult
    func adoptOlderScreenshots() async -> Int {
        guard isWatching, case .success(let scan) = retentionPreview, scan.olderNotTracked > 0 else { return 0 }
        let entries = await ledger.entries()
        let settings = settings
        let now = clock()
        let files = await Task.detached(priority: .userInitiated) { () -> [CaptureFile]? in
            guard CaptureSettings.realPath(settings.folder()) == scan.folder.path else { return nil }
            // The age limit the user saw in the preview.
            return RetentionScanner.stillAdoptable(scan.olderNotTrackedFiles, ledger: entries, now: now, days: scan.days)
        }.value
        guard isWatching, let files else {
            refreshPreview()
            return 0
        }
        await ledger.adopt(files)
        let log = log
        let count = files.count
        Task { await log.info("adopted \(count) older screenshots") }
        refreshPreview()
        refreshRecent()
        return count
    }

    /// The tour's "Add to cleanup": they go with the next cleanup, so cleanup turns on for
    /// the folder the preview showed, as the tour's switch would, then they are adopted.
    /// Returns how many were adopted; 0, and cleanup unchanged, when the folder changed.
    @discardableResult
    func adoptOlderScreenshotsTurningOnCleanup() async -> Int {
        if !preferences.retention.enabled {
            guard await turnOnRetention() else { return 0 }
        }
        return await adoptOlderScreenshots()
    }

    private func runRetention() async {
        let policy = preferences.retention
        guard isWatching, policy.enabled else { return }
        let outcome = await pass.run(policy: policy, now: clock()) { [weak self] in
            self?.preferences.retention == $0
        }
        if case .ran(_, let result) = outcome {
            lastRun = result
            runCount += 1
            // The summary names the last cleanup that did something; an hourly run that
            // found nothing to move does not replace it.
            if result.moved > 0 || result.failed > 0 { preferences.lastRetention = result }
            preferences.totals.trashed += result.moved
            preferences.totals.freedBytes += result.movedBytes
            if retentionPreview != nil { refreshPreview() }
            if result.moved > 0 { refreshRecent() }
        }
        refreshStatus()
    }

    /// Recomputes `retentionPreview` 300 ms after the last call, off the main actor.
    func refreshPreview() {
        guard isWatching else { return }
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDebounce)
            guard !Task.isCancelled else { return }
            await self?.computePreview(generation: generation)
        }
    }

    private func computePreview(generation: Int) async {
        let entries = await ledger.entries()
        let settings = settings
        let policy = preferences.retention
        let now = clock()
        let home = home
        let hasTrash = hasTrash
        let preview = await Task.detached(priority: .utility) {
            Self.preview(settings: settings, policy: policy, ledger: entries, now: now, home: home, hasTrash: hasTrash)
        }.value
        guard isWatching, generation == previewGeneration else { return }
        retentionPreview = preview
    }

    /// What a retention run would move now, with the policy in force (not as if it were on):
    /// the scan `RetentionPass` would make, read off the main actor and moving nothing. A
    /// refusal is why a run would move nothing (an unconfirmed folder above all).
    func retentionScanNow() async -> Result<RetentionScan, Refusal> {
        let entries = await ledger.entries()
        let settings = settings
        let policy = preferences.retention
        let now = clock()
        let home = home
        let hasTrash = hasTrash
        return await Task.detached(priority: .userInitiated) {
            RetentionScanner.scan(
                folder: settings.folder(), policy: policy, ledger: entries, now: now, home: home, hasTrash: hasTrash)
        }.value
    }

    /// Stores the folder the preview showed as confirmed. False when there is no preview,
    /// or the screenshot folder is no longer the one it showed.
    @discardableResult
    func confirmRetentionFolder() async -> Bool {
        guard isWatching, case .success(let scan) = retentionPreview else { return false }
        let settings = settings
        let confirmed = await Task.detached { () -> ConfirmedFolder? in
            guard CaptureSettings.realPath(settings.folder()) == scan.folder.path else { return nil }
            return ConfirmedFolder.of(scan.folder)
        }.value
        guard let confirmed else {
            refreshPreview()
            return false
        }
        preferences.retention.confirmed = confirmed
        refreshStatus()
        return true
    }

    /// Turns retention on for the folder the preview showed: confirms it, then enables.
    /// False, and still off, when there is no preview or the folder changed since.
    @discardableResult
    func turnOnRetention() async -> Bool {
        guard await confirmRetentionFolder() else { return false }
        preferences.retention.enabled = true
        return true
    }

    /// The scan retention would make if it were on and confirmed for the current folder.
    nonisolated static func preview(
        settings: CaptureSettings, policy: RetentionPolicy, ledger: [LedgerEntry], now: Date,
        home: URL, hasTrash: FolderGuard.TrashLookup
    ) -> Result<RetentionScan, Refusal> {
        let folder = settings.folder()
        // A missing folder has no volume to ask about a Trash: say what is wrong instead.
        guard let confirmed = ConfirmedFolder.of(folder) else { return .failure(.folderMissing) }
        var asIfOn = policy
        asIfOn.enabled = true
        asIfOn.confirmed = confirmed
        return RetentionScanner.scan(
            folder: folder, policy: asIfOn, ledger: ledger, now: now, home: home, hasTrash: hasTrash)
    }

    // MARK: - Status and attentions

    private struct Status: Sendable {
        let folder: URL
        let destination: CaptureDestination
        let refusal: Refusal?
        let showThumbnail: Bool
        let format: String
    }

    /// Re-reads the destination, the folder pref and the retention status off the main actor.
    /// One read at a time; a request during a read runs once afterwards.
    func refreshStatus() {
        guard isWatching else { return }
        if statusInFlight {
            statusQueued = true
            return
        }
        statusInFlight = true
        let settings = settings
        let policy = preferences.retention
        let home = home
        let hasTrash = hasTrash
        Task {
            let status = await Task.detached(priority: .utility) { () -> Status in
                let folder = settings.folder()
                return Status(
                    folder: folder, destination: settings.destination(),
                    refusal: Self.retentionRefusal(folder: folder, policy: policy, home: home, hasTrash: hasTrash),
                    showThumbnail: settings.showThumbnail, format: settings.captureFormat())
            }.value
            statusInFlight = false
            statusReads += 1
            if isWatching {
                // Compared first: every assignment notifies, and the closed popover's views
                // would lay out again every 5 s (P2).
                if configuredFolder != status.folder { configuredFolder = status.folder }
                if destination != status.destination { destination = status.destination }
                if retentionRefusal != status.refusal { retentionRefusal = status.refusal }
                if showThumbnail != status.showThumbnail { showThumbnail = status.showThumbnail }
                if captureFormat != status.format { captureFormat = status.format }
                if appliesFromNextScreenshot, !screencaptureUIRunning() { appliesFromNextScreenshot = false }
                recomputeAttentions()
            }
            if statusQueued {
                statusQueued = false
                refreshStatus()
            }
        }
    }

    /// Why retention, while on, would not run on `folder` now. nil when it is off, or when the
    /// folder does not exist (the folder attention already says so).
    nonisolated static func retentionRefusal(
        folder: URL, policy: RetentionPolicy, home: URL, hasTrash: FolderGuard.TrashLookup
    ) -> Refusal? {
        policy.refusal(folder: folder, home: home, hasTrash: hasTrash)
    }

    private func recomputeAttentions() {
        let next: [Attention]
        if isWatching {
            next = Attention.from(
                destination: destination, watchError: watchError, copyFailure: copyFailure,
                retentionRefusal: retentionRefusal,
                folder: configuredFolder ?? watchedFolder ?? home.appendingPathComponent("Desktop", isDirectory: true))
        } else {
            next = []
        }
        guard next != attentions else { return }
        let added = next.contains { !attentions.contains($0) }
        let before = restingIconState
        let shown = iconPose
        let first = attentions.isEmpty && !next.isEmpty
        attentions = next
        if added {
            attentionArrivals += 1
            announce(StatusIconState.attention.accessibilityLabel)
        }
        // Peg swings into the attention pose once, when something first needs fixing; more
        // problems while it already shows "!" change nothing in the menu bar.
        if first { play(.attention, from: before, shown: shown) }
        // Fixed while it still swings: the icon goes to its resting pose at once, so the "!"
        // never swings in after the problem is gone and agrees with what VoiceOver reads.
        if attentions.isEmpty, flashPhase > 0, flashMoment == .attention { endFlash() }
    }

    /// `copyEnabled` goes straight to the coordinator; a retention change re-reads the status.
    private func observePreferences() {
        guard isWatching else { return }
        let token = observationToken
        withObservationTracking {
            _ = preferences.copyEnabled
            _ = preferences.retention
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.preferencesChanged(token: token) }
        }
    }

    private func preferencesChanged(token: Int) {
        guard isWatching, token == observationToken else { return }
        coordinator.isEnabled = preferences.copyEnabled
        if preferences.copyEnabled != observedCopyEnabled {
            // The pose on show before the switch: the resting state it was drawn with.
            let shown = iconPose(rest: .resolve(copyEnabled: observedCopyEnabled, attentions: attentions, flashing: false))
            observedCopyEnabled = preferences.copyEnabled
            // The switch's answer, where it shows: unless "!" covers both states.
            if attentions.isEmpty {
                preferences.copyEnabled
                    ? play(.resume, from: .paused, shown: shown) : play(.pause, from: .idle, shown: shown)
            }
        }
        if preferences.retention != observedPolicy {
            observedPolicy = preferences.retention
            refreshStatus()
            if retentionPreview != nil { refreshPreview() }
        }
        observePreferences()
    }

    // MARK: - Report

    /// A pre-filled GitHub issue with the macOS and app versions and the last 20 log lines.
    /// The log is read off the main actor.
    func reportIssueURL() async -> URL {
        let title = attentions.contains(.couldNotCopy)
            ? "ClipShot saw a screenshot but could not copy it" : "ClipShot issue"
        let logFile = logFile
        let lines = await Task.detached(priority: .userInitiated) { IssueReport.lastLines(of: logFile) }.value
        return IssueReport.url(title: title, osVersion: osVersion, appVersion: appVersion, logLines: lines)
    }
}

// MARK: - Move to Trash and Undo (Addendum A6)

/// In this file so `undoable`, the note and their generations stay `private(set)` or
/// `private`: only these methods keep Undo one at a time and generation-guarded (R-3).
extension AppModel {
    // MARK: - Trash

    enum TrashError: Error, Equatable {
        /// Not a screenshot ClipShot saw being taken (or one the user adopted).
        case notTracked
        /// Not a direct child of the screenshot folder, or the folder is one ClipShot never
        /// touches.
        case outsideFolder
        /// The folder's volume has no Trash; ClipShot never deletes instead.
        case noTrash
        /// The file changed since, or the Trash refused it.
        case failed
    }

    struct TrashedScreenshot: Equatable {
        /// The screenshot as it was shown, for its thumbnail while Undo is offered.
        let file: CaptureFile
        let inTrash: URL
        /// Its ledger entry was an adopted older file, not one ClipShot saw being taken.
        var adopted = false
        /// It was a row of the popover's list when it was moved: its Undo strip keeps a place
        /// in the list (the last one at worst), never jumping to the top.
        var listed = false

        var original: URL { file.url }
    }

    /// A popover note: which failure, and which one it is, so the timer of a replaced note
    /// does not end the newer one.
    struct ActionNote: Equatable {
        let failure: ScreenshotActionFailure
        let generation: Int
    }

    /// Move to Trash as a row of the list and a floating preview (`preview`) ask for it. A
    /// refusal is said where the user acted, in words, with the alert sound as well: on the
    /// preview, or in a note above the popover's list.
    func moveToTrash(_ file: CaptureFile, fromPreview preview: UUID? = nil) async {
        do throws(TrashError) {
            try await trash(file, fromPreview: preview)
        } catch {
            actionFailed(.trash(error), preview: preview)
        }
    }

    /// Undo, from the popover's Undo strip or a preview's. `file`: the screenshot that
    /// preview moved, so a preview never brings back a newer one; nil for the popover strip.
    /// A repeat while that Undo is still putting the file back (a double click, ⌘Z held) is
    /// the same Undo, so it does nothing, and says nothing.
    func putBack(_ file: CaptureFile? = nil, fromPreview preview: UUID? = nil) async {
        guard !restoring else { return }
        if await !undoTrash(expecting: file, fromPreview: preview) { actionFailed(.undo, preview: preview) }
    }

    private func actionFailed(_ failure: ScreenshotActionFailure, preview: UUID?) {
        alert()
        announce(failure.message)
        if let preview {
            previews.showFailure(failure, on: preview)
            return
        }
        noteGeneration += 1
        let note = ActionNote(failure: failure, generation: noteGeneration)
        actionNote = note
        let clock = timerClock
        let end = clock.now + undoLifetime
        Task { [weak self] in
            try? await clock.sleep(until: end)
            guard let self, self.actionNote == note else { return }
            self.actionNote = nil
        }
    }

    /// Moves a screenshot to the Trash: only a file in the ledger, only a direct child of the
    /// watched folder, with retention's folder guard (realpath, not a broad folder, the volume
    /// has a Trash), and only through `FileManager.trashItem`. No confirmation: it can be put
    /// back, from the popover or, when `preview` moved it, from that preview itself.
    func trash(_ file: CaptureFile, fromPreview preview: UUID? = nil) async throws(TrashError) {
        guard let folder = watchedFolder else { throw .outsideFolder }
        let path = FolderGuard.canonicalPath(file.url)
        // A screenshot copied a moment ago may still be on its way into the ledger.
        await ledgerSettled()
        guard await ledger.contains(path: path, resourceID: file.resourceID) else { throw .notTracked }
        let home = home
        let trasher = trasher
        let hasTrash = hasTrash
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL?, TrashError> in
            // The folder resolves, passes retention's guard, and is the file's resolved
            // parent: a direct child, whatever spelling the URL had.
            guard let resolved = FolderGuard.strictRealPath(folder.path),
                  (path as NSString).deletingLastPathComponent == resolved
            else { return .failure(.outsideFolder) }
            switch FolderGuard.refusal(resolvedPath: resolved, home: home, hasTrash: hasTrash) {
            case .systemOrBroad?, .notConfirmed?, .folderMissing?: return .failure(.outsideFolder)
            case .noTrash?: return .failure(.noTrash)
            case nil: break
            }
            guard let current = CaptureFile.inspect(file.url), current.resourceID == file.resourceID else {
                return .failure(.failed)
            }
            do {
                return .success(try trasher.trash(current.url))
            } catch {
                return .failure(.failed)
            }
        }.value
        let inTrash: URL?
        do throws(TrashError) {
            inTrash = try outcome.get()
        } catch {
            throw error
        }
        let entry = await ledger.remove(path: path, resourceID: file.resourceID)
        let name = file.url.lastPathComponent
        let listed = recent.contains { $0.url.lastPathComponent == name }
        let trashed = inTrash.map {
            TrashedScreenshot(file: file, inTrash: $0, adopted: entry?.adopted ?? false, listed: listed)
        }
        offerUndo(trashed)
        // The user's own Move to Trash, seen in the menu bar: Peg lets the picture go.
        // Retention and "Also clean up" never come here.
        play(.release, from: restingIconState)
        if let preview, trashed != nil {
            previews.offerUndo(preview)
            previews.dismiss(file: file, .trash, except: preview)
        } else {
            previews.dismiss(file: file, .trash)
        }
        screenshotLeft(file)
        announce(Copy.Recent.moved)
        preferences.totals.trashed += 1
        let ext = file.url.pathExtension.lowercased()
        let log = log
        Task { await log.info("trashed ext=\(ext)") }
    }

    /// Offers Undo for `trashed` for `undoLifetime`, in place of any earlier one. A trash
    /// whose place in the Trash is unknown offers none, and ends the earlier one too, so Undo
    /// never brings back a file other than the one just moved.
    private func offerUndo(_ trashed: TrashedScreenshot?) {
        undoGeneration += 1
        if let earlier = undoable { previews.endUndo(file: earlier.file) }
        undoable = trashed
        guard let trashed else { return }
        let generation = undoGeneration
        let clock = timerClock
        // Counted from the trash, not from when the task first runs.
        let end = clock.now + undoLifetime
        Task { [weak self] in
            try? await clock.sleep(until: end)
            guard let self, self.undoGeneration == generation else { return }
            self.undoable = nil
            self.previews.endUndo(file: trashed.file)
        }
    }

    /// Puts the screenshot last moved to the Trash back where it was, back in the ledger and
    /// back on show. False when no Undo is on offer (none, or its time is up), when it is for
    /// another screenshot than `file` (when given), or when its place is taken. Its Undo
    /// previews leave either way, except `preview`, which says why it failed.
    ///
    /// The Undo strip stays in the row's place until the file is back, then the row takes
    /// its place again in the same step, so the list never shows the gap or the older
    /// screenshot in between.
    @discardableResult
    func undoTrash(expecting file: CaptureFile? = nil, fromPreview preview: UUID? = nil) async -> Bool {
        guard !restoring, let trashed = undoable, file == nil || trashed.file == file else { return false }
        restoring = true
        defer { restoring = false }
        // Its timer no longer ends it; this does.
        undoGeneration += 1
        let restored = await Task.detached(priority: .userInitiated) { () -> CaptureFile? in
            guard !FileManager.default.fileExists(atPath: trashed.original.path) else { return nil }
            do {
                try FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original)
            } catch {
                return nil
            }
            return CaptureFile.inspect(trashed.original)
        }.value
        guard let restored else {
            if undoable == trashed { undoable = nil }
            previews.endUndo(file: trashed.file, except: preview)
            return false
        }
        previews.endUndo(file: trashed.file)
        await ledger.restore(restored, adopted: trashed.adopted)
        // Back in its place, in the strip's step.
        if let image = thumbnails[trashed.file], thumbnails[restored] == nil { thumbnails[restored] = image }
        recent = RecentScreenshots.inserting(restored, into: recent)
        if undoable == trashed { undoable = nil }
        preferences.totals.trashed = max(0, preferences.totals.trashed - 1)
        refreshRecent()
        // Back, and Peg grips it again.
        play(.grip, from: restingIconState)
        announce(Copy.Recent.putBack)
        return true
    }

    #if DEBUG
    /// The render harness draws the Undo strip without a real Trash (its demo Trash refuses).
    func showUndoForHarness(_ trashed: TrashedScreenshot?) {
        undoable = trashed
    }

    /// The render harness draws a failure note.
    func showNoteForHarness(_ failure: ScreenshotActionFailure?) {
        actionNote = failure.map { ActionNote(failure: $0, generation: 0) }
    }
    #endif
}
