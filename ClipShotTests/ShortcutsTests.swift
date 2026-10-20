import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// The Shortcuts actions and the Focus filter (Addendum C), through the model they call: the
/// popover's selection, the one clipboard write path, the switch and its Peg moments,
/// retention's own run, a Focus pause kept apart from a pause by hand, and no action before
/// the welcome tour is completed.
@MainActor
struct ShortcutsTests {
    /// Screenshots ClipShot saw being taken, oldest first, `age` seconds old each, recorded in
    /// the ledger before watching starts.
    @discardableResult
    private func taken(_ h: ModelHarness, _ shots: [(String, TimeInterval)], now: Date = RT.now()) async throws -> [URL] {
        var urls: [URL] = []
        for (name, age) in shots {
            let url = try RT.shot(name, in: h.folder, age: age, now: now)
            await h.ledger.record(RT.file(url))
            urls.append(url)
        }
        return urls
    }

    private func names(_ files: [ShortcutFile]) -> [String] { files.map(\.name) }

    // MARK: Get Latest / Get Recent Screenshots

    @Test func latestIsTheNewestTrackedScreenshotWithItsBytesNameAndType() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let urls = try await taken(h, [("a.png", 300), ("b.png", 200), ("c.png", 100)])
        #expect(await h.start())
        let files = try await h.model.shortcutScreenshots(count: 1).files
        #expect(names(files) == ["c.png"])
        #expect(files[0].data == (try Data(contentsOf: urls[2])))
        #expect(files[0].fileExtension == "png")
        #expect(files[0].intentFile.filename == "c.png")
        #expect(files[0].intentFile.type == .png)
    }

    /// The same choice as the popover's list: newest first, existing files only, one per
    /// file; the count is kept to 1...10.
    @Test func recentFollowThePopoverSelection() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let urls = try await taken(h, (1...12).map { ("s\($0).png", TimeInterval(1_000 - $0)) })
        // Gone from the folder: never handed out.
        try FileManager.default.moveItem(at: urls[11], to: h.home.appendingPathComponent("moved.png"))
        // In the folder, never seen being taken: not ClipShot's.
        try RT.shot("untracked.png", in: h.folder, age: 1, now: RT.now())
        #expect(await h.start())
        #expect(names(try await h.model.shortcutScreenshots(count: 3).files) == ["s11.png", "s10.png", "s9.png"])
        let four = try await h.model.shortcutScreenshots(count: RecentScreenshots.count).files
        #expect(names(four) == RecentScreenshots.select(
            lastCopied: nil, ledger: await h.ledger.entries(), folder: h.folder).map(\.url.lastPathComponent))
        #expect(try await h.model.shortcutScreenshots(count: 50).files.count == AppModel.shortcutMaxCount)
        #expect(try await h.model.shortcutScreenshots(count: 0).files.count == 1)
    }

    @Test func noScreenshotIsAClearErrorNotAnEmptyFile() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let urls = try await taken(h, [("gone.png", 60)])
        try FileManager.default.moveItem(at: urls[0], to: h.home.appendingPathComponent("gone.png"))
        #expect(await h.start())
        await #expect(throws: ShortcutError.noScreenshots) { try await h.model.shortcutScreenshots(count: 1) }
        await #expect(throws: ShortcutError.noScreenshots) { try await h.model.shortcutCopyLatest() }
        #expect(ShortcutError.noScreenshots.localizedStringResource.key == Copy.Shortcuts.noScreenshots.key)
    }

    // MARK: Copy Latest Screenshot

    /// Copy Latest Screenshot is the popover's Copy on its top row: the same PNG, the same
    /// owner of the clipboard, one more copied, Peg's copy moment and the announcement.
    @Test func copyLatestTakesThePopoversCopyPath() async throws {
        let shortcut = try ModelHarness(), popover = try ModelHarness()
        defer { shortcut.tearDown(); popover.tearDown() }
        for h in [shortcut, popover] {
            try await taken(h, [("old.png", 200), ("new.png", 100)])
            #expect(await h.start())
        }
        try await shortcut.model.shortcutCopyLatest()
        let row = try #require(CaptureFile.inspect(popover.folder.appendingPathComponent("new.png")))
        #expect(await popover.model.copyAgain(file: row))
        for h in [shortcut, popover] {
            let file = try #require(CaptureFile.inspect(h.folder.appendingPathComponent("new.png")))
            #expect(h.pasteboard.writes.count == 1)
            #expect(h.preferences.totals.copied == 1)
            #expect(h.model.isOnClipboard(file))
            #expect(h.model.flashMoment == .copied && h.model.flashPhase == 1)
            #expect(h.announced.last == Copy.screenshotCopied.key)
        }
        #expect(shortcut.pasteboard.writes == popover.pasteboard.writes)
        #expect(shortcut.pasteboard.writes.first?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "PNG data")
    }

    /// An explicit action, as Copy again: it copies while copying is paused, and leaves the
    /// switch paused.
    @Test func copyLatestWorksWhilePaused() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await taken(h, [("shot.png", 100)])
        h.preferences.copyEnabled = false
        #expect(await h.start())
        try await h.model.shortcutCopyLatest()
        #expect(h.pasteboard.writes.count == 1)
        #expect(!h.preferences.copyEnabled)
    }

    @Test func aCopyThatFailsSaysSoAndCountsNothing() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await taken(h, [("shot.png", 100)])
        #expect(await h.start())
        h.pasteboard.failing = true
        await #expect(throws: ShortcutError.copyFailed) { try await h.model.shortcutCopyLatest() }
        #expect(h.preferences.totals.copied == 0)
        #expect(h.model.flashPhase == 0)
        #expect(h.model.actionNote == nil, "said by Shortcuts, not in the popover")
    }

    // MARK: Pause and Resume Copying

    @Test func pauseAndResumeAreTheSwitchWithItsPegMoments() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.model.shortcutSetCopying(false)
        #expect(!h.preferences.copyEnabled)
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        h.timer?.fire(PegMoment.pause.steps)
        try h.model.shortcutSetCopying(true)
        #expect(h.preferences.copyEnabled)
        #expect(await eventually { await h.model.flashMoment == .resume ? h.model.flashPhase > 0 : false })
        #expect(await eventually { await h.model.copyEnabledInPipeline })
    }

    // MARK: Clean Up Old Screenshots Now

    @Test func cleanUpRefusesWhileRetentionIsOff() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await taken(h, [("old.png", 40 * RT.day)])
        #expect(await h.start())
        for preview in [false, true] {
            await #expect(throws: ShortcutError.retentionOff) { try await h.model.shortcutCleanUp(previewOnly: preview) }
        }
        #expect(h.trasher.trashed.isEmpty)
        #expect(!h.preferences.retention.enabled, "never turned on")
    }

    /// Retention's preview rule: a folder nobody confirmed is never cleaned, and a folder
    /// whose volume has no Trash is refused by the folder guard.
    @Test func cleanUpKeepsRetentionsRefusals() async throws {
        let unconfirmed = try ModelHarness()
        defer { unconfirmed.tearDown() }
        try await taken(unconfirmed, [("old.png", 40 * RT.day)])
        unconfirmed.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: nil)
        #expect(await unconfirmed.start())
        for preview in [false, true] {
            await #expect(throws: ShortcutError.retentionRefused(.notConfirmed)) {
                try await unconfirmed.model.shortcutCleanUp(previewOnly: preview)
            }
        }
        #expect(unconfirmed.trasher.trashed.isEmpty)

        let noTrash = try ModelHarness(hasTrash: false)
        defer { noTrash.tearDown() }
        try await taken(noTrash, [("old.png", 40 * RT.day)])
        noTrash.preferences.retention = RT.policy(noTrash.folder)
        #expect(await noTrash.start())
        await #expect(throws: ShortcutError.retentionRefused(.noTrash)) {
            try await noTrash.model.shortcutCleanUp(previewOnly: false)
        }
        #expect(noTrash.trasher.trashed.isEmpty)
        #expect(ShortcutError.retentionRefused(.noTrash).message.key == Copy.Summary.offForFolder.key)
    }

    /// Preview only counts exactly what the run then moves: expired ledger screenshots,
    /// never one ClipShot did not see being taken, a file that is not a screenshot or a
    /// recent one. The run counts as retention does and plays no Peg moment.
    @Test func previewCountsWhatTheRunMoves() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        try await taken(h, [("old 1.png", 40 * RT.day), ("old 2.png", 35 * RT.day), ("recent.png", 2 * RT.day)], now: now)
        try RT.shot("untracked.png", in: h.folder, age: 50 * RT.day, now: now)
        let unmarked = try RT.shot("unmarked.png", in: h.folder, age: 50 * RT.day, now: now, marker: .none)
        await h.ledger.record(RT.file(unmarked))
        // Off while watching starts, so the run at launch moves nothing; then turned on.
        #expect(await h.start())
        h.preferences.retention = RT.policy(h.folder)
        let preview = try await h.model.shortcutCleanUp(previewOnly: true)
        #expect(preview.count == 2 && preview.previewOnly)
        #expect(h.trasher.trashed.isEmpty, "preview moves nothing")
        #expect(h.preferences.totals.trashed == 0)
        let run = try await h.model.shortcutCleanUp(previewOnly: false)
        #expect(run.count == preview.count && run.bytes == preview.bytes && !run.previewOnly)
        #expect(Set(h.trasher.trashed) == ["old 1.png", "old 2.png"])
        #expect(h.preferences.totals.trashed == 2)
        #expect(h.timers.isEmpty, "cleanup plays no Peg moment")
        let again = try await h.model.shortcutCleanUp(previewOnly: false)
        #expect(again.count == 0)
    }

    // MARK: Get: refused files, the folder wait, the size cap

    /// The newest screenshot cannot be read (FileTrust refuses it): Get Latest hands over the
    /// next newest instead of saying there is none.
    @Test func getLatestFallsBackWhenTheNewestIsRefused() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let urls = try await taken(h, [("older.png", 200), ("newest.png", 100)])
        #expect(await h.start())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urls[1].path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls[1].path) }
        #expect(names(try await h.model.shortcutScreenshots(count: 1).files) == ["older.png"])
        #expect(names(try await h.model.shortcutScreenshots(count: 10).files) == ["older.png"])
    }

    /// A ledger entry outside the watched folder (a subfolder, the home folder), or one whose
    /// file became a symlink, is never handed out or copied.
    @Test func filesOutsideTheFolderOrSymlinkedAreNeverHandedOut() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        let sub = h.folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for (name, dir, age) in [("in sub.png", sub, 10.0), ("in home.png", h.home, 20.0)] {
            await h.ledger.record(RT.file(try RT.shot(name, in: dir, age: age, now: now)))
        }
        let linked = try RT.shot("linked.png", in: h.folder, age: 30, now: now)
        await h.ledger.record(RT.file(linked))
        let elsewhere = h.home.appendingPathComponent("target.png")
        try FileManager.default.moveItem(at: linked, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: elsewhere)
        try await taken(h, [("real.png", 300)], now: now)
        #expect(await h.start())
        #expect(names(try await h.model.shortcutScreenshots(count: 10).files) == ["real.png"])
        try await h.model.shortcutCopyLatest()
        let real = try #require(CaptureFile.inspect(h.folder.appendingPathComponent("real.png")))
        #expect(h.model.isOnClipboard(real))
    }

    /// Shortcuts may launch ClipShot just to ask: Get waits for the coordinator to name the
    /// folder instead of answering "No screenshots".
    @Test func getWaitsForTheFolderOnALaunch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        try await taken(h, [("shot.png", 100)])
        h.model.startWatching()
        #expect(h.model.watchedFolder == nil, "asked before the folder is named")
        #expect(names(try await h.model.shortcutScreenshots(count: 1).files) == ["shot.png"])
    }

    /// Get Recent stops before the bytes it holds pass the cap and says so.
    @Test func getRecentStopsAtTheSizeCap() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let urls = try await taken(h, [("a.png", 300), ("b.png", 200), ("c.png", 100)])
        #expect(await h.start())
        let size = try Data(contentsOf: urls[0]).count
        let capped = try await h.model.shortcutScreenshots(count: 3, maxBytes: size * 2)
        #expect(names(capped.files) == ["c.png", "b.png"] && capped.cutShort)
        let whole = try await h.model.shortcutScreenshots(count: 3)
        #expect(whole.files.count == 3 && !whole.cutShort)
        #expect(AppModel.shortcutMaxBytes == 512 * 1_024 * 1_024)
        var note = Copy.Shortcuts.screenshotsCutShort(2)
        note.locale = Locale(identifier: "sk")
        #expect(String(localized: note) == "2\u{00A0}snímky. Ostatné sú príliš veľké na to, aby sa dali získať naraz.")
    }

    // MARK: Focus filter

    /// A harness on a manual clock, started, with the Focus's grace under the test's control.
    private func focusHarness(onboardingShown: Bool = true) async throws -> (ModelHarness, ManualTimerClock) {
        let clock = ManualTimerClock()
        let h = try ModelHarness(onboardingShown: onboardingShown, timerClock: clock)
        return (h, clock)
    }

    /// The Focus ends and its grace runs out.
    private func focusEnds(_ h: ModelHarness, _ clock: ManualTimerClock) async throws {
        let settled = h.model.focusGracesSettled
        let scheduled = h.preferences.focusPause.pausedCopying
        try h.model.shortcutFocusChanged(pausing: false)
        guard scheduled else { return }
        #expect(await eventually { clock.waiting == 1 })
        clock.advance(by: AppModel.focusOffGrace)
        #expect(await eventually { await h.model.focusGracesSettled == settled + 1 })
    }

    /// The precedence matrix: a Focus pause is undone by the Focus only, a pause by hand is
    /// never undone by a Focus, and a Resume by hand during the Focus holds until it changes.
    @Test func focusPausesAndResumesOnlyWhatItPaused() async throws {
        let (h, clock) = try await focusHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let model = h.model, prefs = h.preferences

        // Copying on; the Focus pauses it and its end resumes it.
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && model.pausedByFocus)
        try await focusEnds(h, clock)
        #expect(prefs.copyEnabled && !model.pausedByFocus)

        // Paused by hand first: the Focus leaves it, and its end resumes nothing.
        model.setCopying(false)
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && !model.pausedByFocus)
        try await focusEnds(h, clock)
        #expect(!prefs.copyEnabled)
        model.setCopying(true)

        // Resumed by hand during the Focus: the same report again keeps it on, the end
        // changes nothing, the next Focus pauses again.
        try model.shortcutFocusChanged(pausing: true)
        model.setCopying(true)
        #expect(prefs.copyEnabled && !model.pausedByFocus)
        try model.shortcutFocusChanged(pausing: true)
        #expect(prefs.copyEnabled, "a Resume by hand wins until the Focus changes")
        try await focusEnds(h, clock)
        #expect(prefs.copyEnabled)
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && model.pausedByFocus)

        // Resumed, then paused again by hand during the Focus: its end does not resume.
        model.setCopying(true)
        model.setCopying(false)
        try await focusEnds(h, clock)
        #expect(!prefs.copyEnabled)
        model.setCopying(true)

        // Pause Copying from Shortcuts during a Focus pause is a pause by hand.
        try model.shortcutFocusChanged(pausing: true)
        try model.shortcutSetCopying(false)
        #expect(!model.pausedByFocus)
        try await focusEnds(h, clock)
        #expect(!prefs.copyEnabled)
    }

    /// From one pausing Focus straight to another: the first one's end, then the next one.
    /// Copying stays paused throughout, with no Peg moment and no resume afterwards.
    @Test func aSwitchBetweenPausingFocusModesStaysPaused() async throws {
        let (h, clock) = try await focusHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.model.shortcutFocusChanged(pausing: true)
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        h.timer?.fire(PegMoment.pause.steps)
        let timers = h.timers.count
        try h.model.shortcutFocusChanged(pausing: false)
        #expect(!h.preferences.copyEnabled, "the end waits for its grace")
        #expect(!h.model.pausedByFocus, "no Focus is on meanwhile")
        try h.model.shortcutFocusChanged(pausing: true)
        #expect(await eventually { clock.waiting == 1 })
        clock.advance(by: AppModel.focusOffGrace)
        #expect(await eventually { await h.model.focusGracesSettled == 1 })
        #expect(!h.preferences.copyEnabled && h.model.pausedByFocus)
        #expect(h.timers.count == timers && h.model.flashPhase == 0, "no Peg moment")
        // The second Focus ends: copying resumes.
        try await focusEnds(h, clock)
        #expect(h.preferences.copyEnabled)
    }

    @Test func aFocusPausePlaysThePegMomentsOfTheSwitch() async throws {
        let (h, clock) = try await focusHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.model.shortcutFocusChanged(pausing: true)
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        h.timer?.fire(PegMoment.pause.steps)
        try await focusEnds(h, clock)
        #expect(await eventually { await h.model.flashMoment == .resume ? h.model.flashPhase > 0 : false })
    }

    /// The popover's status line says why: the Focus, not the switch.
    @Test func thePopoverSaysAFocusPausedCopying() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        func header() -> HeaderStatus {
            HeaderStatus.of(
                state: h.model.headerState, previewMode: h.model.previewMode,
                showsThumbnailWait: h.model.showsThumbnailWait, attentions: h.model.attentions.count,
                pausedByFocus: h.model.pausedByFocus)
        }
        try h.model.shortcutFocusChanged(pausing: true)
        #expect(header() == HeaderStatus(state: .paused, detail: .pausedByFocus))
        #expect(header().detailText.key == Copy.Header.pausedByFocus.key)
        h.model.setCopying(true)
        h.model.setCopying(false)
        #expect(header() == HeaderStatus(state: .paused, detail: .paused))
    }

    /// The pause and who made it are kept across launches.
    @Test func theFocusPauseSurvivesARelaunch() {
        let store = InMemoryPreferenceStore()
        let before = Preferences(store: store)
        before.copyEnabled = false
        before.focusPause = FocusPause(focusOn: true, pausedCopying: true)
        let after = Preferences(store: store)
        #expect(after.focusPause == FocusPause(focusOn: true, pausedCopying: true))
        #expect(!after.copyEnabled)
        #expect(Preferences(store: InMemoryPreferenceStore()).focusPause == FocusPause())
    }

    // MARK: The Focus at launch

    private func logged(_ h: ModelHarness, _ text: String) async -> Bool {
        await eventually { (try? String(contentsOf: h.logFile, encoding: .utf8))?.contains(text) == true }
    }

    /// A harness started as at a launch after a Focus paused copying.
    private func launchedPausedByFocus() async throws -> ModelHarness {
        let h = try ModelHarness()
        h.preferences.copyEnabled = false
        h.preferences.focusPause = FocusPause(focusOn: true, pausedCopying: true)
        #expect(await h.start())
        return h
    }

    @Test func aFocusThatEndedWhileQuitResumesAtLaunch() async throws {
        let h = try await launchedPausedByFocus()
        defer { h.tearDown() }
        await h.model.reconcileFocusAtLaunch { false }
        #expect(h.preferences.copyEnabled && h.preferences.focusPause == FocusPause())
        #expect(await logged(h, "focus at launch: no pausing Focus"))
    }

    /// ClipShot quit within the grace after a Focus ended: the Focus is off but still holds
    /// the pause. With no pausing Focus at launch, copying comes back.
    @Test func aResumeLostInTheGraceIsMadeAtLaunch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.copyEnabled = false
        h.preferences.focusPause = FocusPause(focusOn: false, pausedCopying: true)
        #expect(await h.start())
        await h.model.reconcileFocusAtLaunch { false }
        #expect(h.preferences.copyEnabled && h.preferences.focusPause == FocusPause())
        #expect(await eventually { await h.model.flashMoment == .resume ? h.model.flashPhase > 0 : false })
    }

    /// The same, but the user paused by hand meanwhile: the pause stays.
    @Test func aPauseByHandStaysWhenNoFocusIsOnAtLaunch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.copyEnabled = false
        h.preferences.focusPause = FocusPause(focusOn: false, pausedCopying: false)
        #expect(await h.start())
        await h.model.reconcileFocusAtLaunch { false }
        #expect(!h.preferences.copyEnabled)
    }

    @Test func aFocusThatBeganWhileQuitPausesAtLaunch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        await h.model.reconcileFocusAtLaunch { true }
        #expect(!h.preferences.copyEnabled && h.model.pausedByFocus)
        #expect(await logged(h, "focus at launch: a pausing Focus is on"))
    }

    /// The read fails: copying is not left paused on a guess, the popover no longer says a
    /// Focus is on, and the log says why.
    @Test func anUnknownFocusAtLaunchResumesWhatTheFocusPaused() async throws {
        struct Unavailable: Error {}
        let h = try await launchedPausedByFocus()
        defer { h.tearDown() }
        await h.model.reconcileFocusAtLaunch { throw Unavailable() }
        #expect(h.preferences.copyEnabled && !h.model.pausedByFocus)
        #expect(h.preferences.focusPause == FocusPause())
        #expect(await logged(h, "focus at launch unknown (Unavailable); resumed the pause it made"))
    }

    @Test func anUnknownFocusAtLaunchKeepsAPauseByHand() async throws {
        struct Unavailable: Error {}
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.copyEnabled = false
        #expect(await h.start())
        await h.model.reconcileFocusAtLaunch { throw Unavailable() }
        #expect(!h.preferences.copyEnabled)
        #expect(await logged(h, "focus at launch unknown (Unavailable); nothing to resume"))
    }

    /// A read that never answers counts as unknown once the timeout passes; meanwhile the
    /// popover does not claim a Focus is on.
    @Test func aFocusReadThatHangsTimesOut() async throws {
        let h = try await launchedPausedByFocus()
        defer { h.tearDown() }
        let seen = Mutex<Bool?>(nil)
        let model = h.model
        await model.reconcileFocusAtLaunch(timeout: .milliseconds(100)) {
            let claimed = await MainActor.run { model.pausedByFocus }
            seen.withLock { $0 = claimed }
            try await Task.sleep(for: .seconds(60))
            return true
        }
        #expect(seen.withLock { $0 } == false, "no Focus claimed while unknown")
        #expect(h.preferences.copyEnabled && h.model.focusStateKnown)
        #expect(await logged(h, "focus at launch unknown (FocusReadTimedOut)"))
    }

    // MARK: Before the tour

    /// Until the welcome tour is completed, every action and the Focus filter refuse with
    /// "Finish setting up ClipShot first" and change nothing.
    @Test func nothingRunsBeforeTheTourIsCompleted() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        try await taken(h, [("old.png", 40 * RT.day)])
        h.preferences.retention = RT.policy(h.folder)
        #expect(!h.preferences.tourCompleted)
        try await refusesEverything(h)
        #expect(!h.model.isWatching, "the folder was not touched")
        #expect(ShortcutError.notSetUp.localizedStringResource.key == Copy.Shortcuts.notSetUp.key)
    }

    /// The tour's Start copying is watching already, the tour is not done: still refused. A
    /// Focus reported meanwhile applies when the tour is done.
    @Test func duringTheTourActionsRefuseAndAFocusWaitsForItsEnd() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        // Retention stays off: started watching runs retention on its own terms.
        try await taken(h, [("old.png", 40 * RT.day)])
        h.model.startWatching()
        #expect(await eventually { await h.model.watchedFolder != nil })
        try await refusesEverything(h)
        h.model.finishOnboarding()
        #expect(h.preferences.tourCompleted)
        #expect(!h.preferences.copyEnabled && h.model.pausedByFocus, "the Focus reported during the tour")
        #expect(h.model.focusDuringTour == nil)
    }

    private func refusesEverything(_ h: ModelHarness) async throws {
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutScreenshots(count: 1) }
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutCopyLatest() }
        #expect(throws: ShortcutError.notSetUp) { try h.model.shortcutSetCopying(false) }
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutCleanUp(previewOnly: false) }
        #expect(throws: ShortcutError.notSetUp) { try h.model.shortcutFocusChanged(pausing: true) }
        #expect(h.preferences.copyEnabled)
        #expect(h.preferences.focusPause == FocusPause())
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.trasher.trashed.isEmpty)
    }

    // MARK: Metadata

    /// The build extracted the App Intents metadata: every action, the Focus filter, the App
    /// Shortcuts with the app name in each phrase, each phrase translated in every language.
    @Test func theAppShortcutsMetadataIsInTheApp() throws {
        let resources = try #require(Bundle.main.resourceURL)
        let metadata = resources.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let actions = try #require(json["actions"] as? [String: Any])
        #expect(Set(actions.keys) == [
            "GetLatestScreenshotIntent", "GetRecentScreenshotsIntent", "CopyLatestScreenshotIntent",
            "PauseCopyingIntent", "ResumeCopyingIntent", "CleanUpOldScreenshotsIntent", "CopyingFocusFilter",
        ])
        for case let action as [String: Any] in actions.values {
            #expect(action["openAppWhenRun"] as? Bool == false, "no window opens")
        }
        let shortcuts = try #require(json["autoShortcuts"] as? [[String: Any]])
        #expect(shortcuts.count == 5)
        let phrases = shortcuts.flatMap { ($0["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String } }
        #expect(phrases.count == 10)
        #expect(phrases.allSatisfy { $0.contains("${applicationName}") })
        for language in ["en", "sk", "cs", "de", "es", "fr"] {
            let table = resources.appendingPathComponent("\(language).lproj/AppShortcuts.strings")
            let strings = try #require(NSDictionary(contentsOf: table) as? [String: String], "\(language)")
            for phrase in phrases {
                let translated = try #require(strings[phrase], "\(language): \(phrase)")
                #expect(translated.contains("${applicationName}"), "\(language): \(translated)")
            }
        }
    }
}
