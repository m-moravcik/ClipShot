import Foundation
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
        let files = try await h.model.shortcutScreenshots(count: 1)
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
        #expect(names(try await h.model.shortcutScreenshots(count: 3)) == ["s11.png", "s10.png", "s9.png"])
        let four = try await h.model.shortcutScreenshots(count: RecentScreenshots.count)
        #expect(names(four) == RecentScreenshots.select(
            lastCopied: nil, ledger: await h.ledger.entries(), folder: h.folder).map(\.url.lastPathComponent))
        #expect(try await h.model.shortcutScreenshots(count: 50).count == AppModel.shortcutMaxCount)
        #expect(try await h.model.shortcutScreenshots(count: 0).count == 1)
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

    // MARK: Focus filter

    /// The precedence matrix: a Focus pause is undone by the Focus only, a pause by hand is
    /// never undone by a Focus, and a Resume by hand during the Focus holds until it changes.
    @Test func focusPausesAndResumesOnlyWhatItPaused() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let model = h.model, prefs = h.preferences

        // Copying on; the Focus pauses it and its end resumes it.
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && model.pausedByFocus)
        try model.shortcutFocusChanged(pausing: false)
        #expect(prefs.copyEnabled && !model.pausedByFocus)

        // Paused by hand first: the Focus leaves it, and its end resumes nothing.
        model.setCopying(false)
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && !model.pausedByFocus)
        try model.shortcutFocusChanged(pausing: false)
        #expect(!prefs.copyEnabled)
        model.setCopying(true)

        // Resumed by hand during the Focus: the same report again keeps it on, the end
        // changes nothing, the next Focus pauses again.
        try model.shortcutFocusChanged(pausing: true)
        model.setCopying(true)
        #expect(prefs.copyEnabled && !model.pausedByFocus)
        try model.shortcutFocusChanged(pausing: true)
        #expect(prefs.copyEnabled, "a Resume by hand wins until the Focus changes")
        try model.shortcutFocusChanged(pausing: false)
        #expect(prefs.copyEnabled)
        try model.shortcutFocusChanged(pausing: true)
        #expect(!prefs.copyEnabled && model.pausedByFocus)

        // Resumed, then paused again by hand during the Focus: its end does not resume.
        model.setCopying(true)
        model.setCopying(false)
        try model.shortcutFocusChanged(pausing: false)
        #expect(!prefs.copyEnabled)
        model.setCopying(true)

        // Pause Copying from Shortcuts during a Focus pause is a pause by hand.
        try model.shortcutFocusChanged(pausing: true)
        try model.shortcutSetCopying(false)
        #expect(!model.pausedByFocus)
        try model.shortcutFocusChanged(pausing: false)
        #expect(!prefs.copyEnabled)
    }

    @Test func aFocusPausePlaysThePegMomentsOfTheSwitch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.model.shortcutFocusChanged(pausing: true)
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        h.timer?.fire(PegMoment.pause.steps)
        try h.model.shortcutFocusChanged(pausing: false)
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

    /// A Focus that ends while ClipShot is not running still resumes what it paused.
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

    // MARK: Before the tour

    /// Until the welcome tour is completed, every action that changes something, and the
    /// Focus filter, refuse with "Finish setting up ClipShot first" and change nothing.
    @Test func nothingRunsBeforeTheTourIsCompleted() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        try await taken(h, [("old.png", 40 * RT.day)])
        h.preferences.retention = RT.policy(h.folder)
        #expect(!h.preferences.tourCompleted)
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutScreenshots(count: 1) }
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutCopyLatest() }
        #expect(throws: ShortcutError.notSetUp) { try h.model.shortcutSetCopying(false) }
        await #expect(throws: ShortcutError.notSetUp) { try await h.model.shortcutCleanUp(previewOnly: false) }
        #expect(throws: ShortcutError.notSetUp) { try h.model.shortcutFocusChanged(pausing: true) }
        #expect(h.preferences.copyEnabled)
        #expect(h.preferences.focusPause == FocusPause())
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.trasher.trashed.isEmpty)
        #expect(!h.model.isWatching, "the folder was not touched")
        #expect(ShortcutError.notSetUp.localizedStringResource.key == Copy.Shortcuts.notSetUp.key)
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
