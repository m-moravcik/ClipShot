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
    static let flashTolerance: TimeInterval = 0.025
    static let markupTipAfterCopies = 3
    static let previewDebounce: Duration = .milliseconds(300)

    let preferences: Preferences

    private(set) var isWatching = false
    private(set) var flashPhase = 0
    /// Reduce Motion as read when the current flash started.
    private(set) var flashReduceMotion = false
    private(set) var attentions: [Attention] = []
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
    /// `lastCopied` with its decoded thumbnail. Follows `lastCopied` once the thumbnail is
    /// decoded (or failed to), so the card swaps in one step.
    private(set) var latest: LatestCapture?
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

    /// Preview mode macOS, after the offer: a quiet line in the header says copying waits.
    var showsThumbnailWait: Bool {
        isWatching && previewModeKnown && previewMode == .macOS && !showsPreviewOffer
    }

    var iconState: StatusIconState {
        .resolve(copyEnabled: preferences.copyEnabled, attentions: attentions, flashing: flashPhase > 0)
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

    /// The first-copy hint (when a screenshot can be pasted in this Preview mode), until the
    /// first copy.
    var showFirstCopyHint: Bool { !preferences.firstCopyDone }

    /// The one-time Markup tip, from the third copy until dismissed.
    var showMarkupTip: Bool {
        !preferences.markupTipShown && preferences.totals.copied >= Self.markupTipAfterCopies
    }

    var launchAtLogin: Bool { preferences.launchAtLoginIntent ?? false }

    // MARK: - Collaborators

    @ObservationIgnored private let settings: CaptureSettings
    @ObservationIgnored private let screencapturePrefs: any ScreencapturePreferences
    @ObservationIgnored private let backup: PrefsBackup
    @ObservationIgnored let home: URL
    @ObservationIgnored let pasteboard: any PasteboardWriting
    @ObservationIgnored let ledger: ScreenshotLedger
    @ObservationIgnored let hasTrash: FolderGuard.TrashLookup
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let statusInterval: Duration
    @ObservationIgnored private let makeFlashTimer: AppDependencies.MakeFlashTimer
    @ObservationIgnored private let reduceMotion: @MainActor () -> Bool
    @ObservationIgnored let playSound: @MainActor () -> Void
    @ObservationIgnored let announce: @MainActor (LocalizedStringResource) -> Void
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
    @ObservationIgnored let trasher: any Trashing
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
    /// The capture whose thumbnail is being decoded for `latest`.
    @ObservationIgnored private var thumbnailFor: CaptureFile?
    @ObservationIgnored private var flash = CopiedFlash()
    @ObservationIgnored private var flashTimer: (any FlashTimer)?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var statusInFlight = false
    @ObservationIgnored private var statusQueued = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var observationToken = 0
    @ObservationIgnored private var observedPolicy: RetentionPolicy?
    /// The panel that shows `previews`, made when watching first starts.
    @ObservationIgnored private var previewHost: AnyObject?
    /// The pasteboard's change count right after ClipShot's last write: when it differs, the
    /// clipboard holds something else and the preview offers Copy again.
    @ObservationIgnored var changeCountAfterCopy: Int?
    /// The last screenshot moved to the Trash from a preview, for Undo.
    @ObservationIgnored var lastTrashed: TrashedScreenshot?

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
        playSound = d.playSound
        announce = d.announce
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
        previews = FloatingPreviews(lifetime: d.previewLifetime)
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

    /// At app start: resumes watching once onboarding has been shown.
    func launch() {
        if preferences.onboardingShown { startWatching() }
    }

    /// The first moment ClipShot touches the screenshot folder, prefs, pasteboard and login item.
    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        preferences.launchAtLoginIntent = reconcileLoginItem(preferences.launchAtLoginIntent)
        observedPolicy = preferences.retention
        coordinator.isEnabled = preferences.copyEnabled
        coordinator.start()
        if previewHost == nil { previewHost = makePreviewHost(self) }
        observePreferences()
        statusTask = Task { [weak self, statusInterval] in
            while !Task.isCancelled {
                // Not held across the sleep, so a released model ends the loop.
                guard let model = self else { return }
                model.refreshStatus()
                try? await Task.sleep(for: statusInterval)
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
    /// starts too, as it would at the next launch.
    func finishOnboarding() {
        startWatching()
        preferences.onboardingShown = true
    }

    /// Settings > General: shows the welcome tour again the next time the popover opens.
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

    private func coordinatorChanged() {
        lastCopied = coordinator.lastCopied
        updateLatest()
        watchError = coordinator.watchError
        let folderChanged = watchedFolder != coordinator.watchedFolder
        watchedFolder = coordinator.watchedFolder
        recomputeAttentions()
        if folderChanged {
            refreshStatus()
            if retentionPreview != nil { refreshPreview() }
        }
    }

    private func copied(_ file: CaptureFile) {
        changeCountAfterCopy = pasteboard.changeCount
        lastCopied = file
        updateLatest()
        if previewModeKnown, previewMode.showsOwnPreview { showPreview(file) }
        preferences.totals.copied += 1
        preferences.firstCopyDone = true
        clearCopyFailure()
        startFlash()
        if preferences.copySound { playSound() }
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

    /// Decodes the thumbnail off the main actor, then moves `latest` to `lastCopied`.
    private func updateLatest() {
        guard let file = lastCopied else {
            thumbnailFor = nil
            latest = nil
            return
        }
        guard latest?.file != file, thumbnailFor != file else { return }
        thumbnailFor = file
        Task { [weak self] in
            let thumbnail = await Task.detached(priority: .utility) {
                Thumbnailer.decode(file.url, maxPixelSize: LatestCapture.thumbnailPixels)
            }.value
            guard let self, self.thumbnailFor == file else { return }
            self.thumbnailFor = nil
            self.latest = LatestCapture(file: file, thumbnail: thumbnail)
        }
    }

    private func copyFailed(_ file: CaptureFile) {
        copyFailure = clock()
        failedCapture = file
        recomputeAttentions()
    }

    private func clearCopyFailure() {
        guard copyFailure != nil || failedCapture != nil else { return }
        copyFailure = nil
        failedCapture = nil
        recomputeAttentions()
    }

    /// One timer per flash: a copy during the flash restarts the phases on the same timer.
    func startFlash() {
        if flashTimer == nil {
            flashReduceMotion = reduceMotion()
            flash = CopiedFlash(reduceMotion: flashReduceMotion)
            flashTimer = makeFlashTimer(CopiedFlash.interval, Self.flashTolerance) { [weak self] in
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

    /// Copies the screenshot that failed, or else the latest one, again.
    @discardableResult
    func copyAgain() async -> Bool {
        guard let file = failedCapture ?? lastCopied else { return false }
        return await copyAgain(file: file)
    }

    /// Copies `file` again: the latest card passes the screenshot it shows. Clears the
    /// could-not-copy attention only when `file` is the one that failed.
    @discardableResult
    func copyAgain(file: CaptureFile) async -> Bool {
        let png = await Task.detached(priority: .userInitiated) { PNGConverter.pngData(from: file.url) }.value
        let ext = file.url.pathExtension.lowercased()
        let log = log
        guard let png, pasteboard.writePNG(png) else {
            Task { await log.error("copy again failed ext=\(ext)") }
            return false
        }
        Task { await log.info("copied again ext=\(ext)") }
        changeCountAfterCopy = pasteboard.changeCount
        if file == failedCapture { clearCopyFailure() }
        announce(Copy.screenshotCopied)
        return true
    }

    /// The page in System Settings where folder access is granted (spike F15).
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    func openPrivacySettings() {
        workspace.open(Self.privacySettingsURL)
    }

    /// Opens the Trash of the screenshot folder's volume.
    func showTrash() async {
        let folder = screenshotFolder ?? home
        let trash = await Task.detached(priority: .userInitiated) {
            try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false)
        }.value
        if let trash { workspace.open(trash) }
    }

    func revealLast() {
        guard let file = lastCopied else { return }
        workspace.reveal(file.url)
    }

    func openFolder() {
        guard let folder = screenshotFolder else { return }
        workspace.open(folder)
    }

    func dismissMarkupTip() {
        preferences.markupTipShown = true
    }

    /// Something other than ClipShot's last copy is on the clipboard now.
    var clipboardChangedSinceCopy: Bool {
        guard let changeCountAfterCopy else { return true }
        return pasteboard.changeCount != changeCountAfterCopy
    }

    // MARK: - Native settings

    func fixDestination() async {
        let settings = settings
        await Task.detached { settings.fixDestination() }.value
        nativeSettingChanged()
    }

    /// The upgrade offer's Copy at once.
    func acceptPreviewOffer() async {
        await setPreviewMode(.clipShot)
    }

    /// The upgrade offer's close: never offered again.
    func dismissPreviewOffer() {
        preferences.previewModeApplied = true
    }

    /// Settings > Capture > Preview. Writes `show-thumbnail` through the backup-once path.
    func setPreviewMode(_ mode: PreviewMode) async {
        preferences.previewMode = mode
        preferences.previewModeApplied = true
        await writeShowThumbnail(mode.showsSystemThumbnail)
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
            await writeShowThumbnail(wanted)
            let log = log
            Task { await log.info("preview mode applied, thumbnail \(wanted ? "on" : "off")") }
        } else {
            showThumbnail = current
        }
        preferences.previewModeApplied = true
    }

    private func writeShowThumbnail(_ on: Bool) async {
        let settings = settings
        await Task.detached { settings.showThumbnail = on }.value
        // At once, so the picker does not flip back until the next read; that read corrects
        // it if the write was refused.
        showThumbnail = on
        nativeSettingChanged()
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
    /// ledger, after the user confirmed "Also clean up N older screenshots". They then go with
    /// the next run. Returns how many were adopted; 0 when there is no preview or the folder
    /// is no longer the one it showed.
    @discardableResult
    func adoptOlderScreenshots() async -> Int {
        guard isWatching, case .success(let scan) = retentionPreview, scan.olderNotTracked > 0 else { return 0 }
        let entries = await ledger.entries()
        let settings = settings
        let now = clock()
        // The age limit the user saw in the preview.
        let policy = RetentionPolicy(enabled: true, days: scan.days, confirmed: nil)
        let files = await Task.detached(priority: .userInitiated) { () -> [CaptureFile]? in
            guard CaptureSettings.realPath(settings.folder()) == scan.folder.path else { return nil }
            return RetentionScanner.adoptable(folder: scan.folder, ledger: entries, now: now, policy: policy)
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
        return count
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
        var asIfOn = policy
        asIfOn.enabled = true
        asIfOn.confirmed = ConfirmedFolder.of(folder)
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
            if isWatching {
                configuredFolder = status.folder
                destination = status.destination
                retentionRefusal = status.refusal
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
        guard policy.enabled else { return nil }
        let resolved = URL(fileURLWithPath: CaptureSettings.realPath(folder), isDirectory: true)
        guard let current = ConfirmedFolder.of(resolved) else { return nil }
        if let refusal = FolderGuard.refusal(resolvedPath: current.path, home: home, hasTrash: hasTrash) {
            return refusal
        }
        return policy.confirmed == current ? nil : .notConfirmed
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
        attentions = next
        if added { announce(StatusIconState.attention.accessibilityLabel) }
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
