import Foundation
import Testing
@testable import ClipShot

/// The welcome tour on a real model: steps, the first folder access, "Try it", and the one
/// rule that matters most, that only Done and Skip record the tour as shown.
@MainActor
struct OnboardingTests {
    @Test func stepsGoForwardAndBack() throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = WelcomeTour()
        #expect(tour.step == .welcome)
        #expect(tour.number == 1)
        #expect(!tour.canGoBack)
        #expect(tour.primary(h.model) == .next)
        tour.back()
        #expect(tour.step == .welcome, "Back on the first step stays there")

        tour.advance(h.model)
        #expect(tour.step == .folder)
        #expect(tour.number == 2)
        #expect(tour.canGoBack)
        tour.back()
        #expect(tour.step == .welcome)
        #expect(WelcomeTour.stepCount == 3)
    }

    @Test func directionFollowsNavigation() throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = WelcomeTour()
        #expect(tour.direction == .forward)
        tour.advance(h.model)
        #expect(tour.direction == .forward)
        tour.back()
        #expect(tour.direction == .backward)
        tour.back()
        #expect(tour.step == .welcome)
        tour.advance(h.model)
        #expect(tour.direction == .forward, "Next after Back slides forward again")
    }

    @Test func tryItSaysCopyingIsOffInsteadOfWaiting() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        h.preferences.copyEnabled = false
        var tour = WelcomeTour(step: .folder)
        tour.advance(h.model)
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
        #expect(tour.tryState(h.model) == .paused)

        // The note's button turns copying back on; then Try it waits, and gets the copy.
        h.preferences.copyEnabled = true
        #expect(tour.tryState(h.model) == .waiting)
        try await Task.sleep(for: .milliseconds(200))
        try h.shoot("Screenshot 1.png")
        let trying = tour
        #expect(await eventually {
            if case .copied(let file) = await trying.tryState(h.model) {
                return file.url.lastPathComponent == "Screenshot 1.png"
            }
            return false
        })
    }

    @Test func tryItShowsWhatBlocksCopyingBeforeThePausedNote() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        h.prefs["target"] = "clipboard"
        h.preferences.copyEnabled = false
        var tour = WelcomeTour(step: .folder)
        tour.advance(h.model)
        #expect(await eventually { await !h.model.attentions.isEmpty })
        #expect(tour.tryState(h.model) == .attention(.destinationNotFile))
    }

    @Test func step2StartCopyingIsTheFirstFolderAccess() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        h.model.launch()
        var tour = WelcomeTour()
        tour.advance(h.model)
        // Step 2 shows the explanation; nothing has touched the folder or the prefs yet.
        #expect(tour.step == .folder)
        #expect(tour.primary(h.model) == .startCopying)
        #expect(h.events.starts == 0)
        #expect(h.prefs.synchronizeCount == 0)
        #expect(!h.model.isWatching)

        tour.advance(h.model)
        #expect(tour.step == .folder, "Start copying stays on step 2 for Try it")
        #expect(h.model.isWatching)
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
        #expect(h.events.starts == 1)
        #expect(tour.primary(h.model) == .next)
        #expect(!h.preferences.onboardingShown)
    }

    @Test func tryItWaitsForTheFirstCopyThenShowsIt() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = WelcomeTour(step: .folder)
        tour.advance(h.model)
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
        #expect(tour.tried(h.model) == nil, "waits for a screenshot")

        try h.shoot("Screenshot 1.png")
        let trying = tour
        #expect(await eventually { await trying.tried(h.model)?.url.lastPathComponent == "Screenshot 1.png" })
        // The copied state shows the decoded thumbnail of that same screenshot.
        #expect(await eventually { await h.model.latest?.file == trying.tried(h.model) })
        #expect(h.model.latest?.thumbnail != nil)
        #expect(!h.preferences.onboardingShown, "a copy does not end the tour")
    }

    @Test func replayedTourIgnoresTheEarlierCopy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot old.png")
        #expect(await eventually { await h.model.lastCopied != nil })

        h.model.replayOnboarding()
        #expect(!h.preferences.onboardingShown)
        var tour = WelcomeTour()
        tour.advance(h.model)
        // Already watching: step 2 goes straight to Try it, with no access button.
        #expect(tour.step == .folder)
        #expect(tour.trying)
        #expect(tour.primary(h.model) == .next)
        #expect(tour.tried(h.model) == nil, "the screenshot from before the replay is not the try")

        try h.shoot("Screenshot new.png", size: 24)
        let trying = tour
        #expect(await eventually { await trying.tried(h.model)?.url.lastPathComponent == "Screenshot new.png" })
    }

    @Test func onboardingShownOnlyOnDone() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = WelcomeTour()
        tour.advance(h.model) // welcome -> folder
        tour.advance(h.model) // Start copying
        tour.advance(h.model) // folder -> tidy
        #expect(tour.step == .tidy)
        #expect(tour.primary(h.model) == .done)
        tour.back()
        tour.advance(h.model)
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.lastCopied != nil })
        #expect(!h.preferences.onboardingShown, "no step, copy or Back records the tour")

        tour.advance(h.model) // Done
        #expect(h.preferences.onboardingShown)
        #expect(h.model.isWatching)
    }

    // MARK: - Launch at login (owner decision 2026-10-20: on by default in the tour)

    /// Walks a fresh tour to step 3: Next, Start copying, Next.
    private func toStep3(_ h: ModelHarness) async -> WelcomeTour {
        var tour = WelcomeTour()
        tour.advance(h.model)
        tour.advance(h.model)
        _ = await eventually { await h.model.watchedFolder?.path == h.folder.path }
        tour.advance(h.model)
        return tour
    }

    @Test func launchAtLoginStartsOnAndDoneRegistersIt() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = await toStep3(h)
        #expect(tour.step == .tidy)
        #expect(h.model.launchAtLogin, "the switch starts on")
        #expect(h.loginItemSets.isEmpty, "nothing registered before the user has seen it")
        #expect(h.loginReconciles == 0, "Start copying did not adopt the system's off")
        tour.advance(h.model) // Done
        #expect(h.loginItemSets == [true])
        #expect(h.preferences.launchAtLoginIntent == true)
        #expect(h.model.launchAtLogin)
    }

    @Test func switchingItOffInTheTourIsKept() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = await toStep3(h)
        h.model.setLaunchAtLogin(false)
        tour.advance(h.model) // Done
        #expect(h.loginItemSets == [false])
        #expect(h.preferences.launchAtLoginIntent == false)
        #expect(!h.model.launchAtLogin)
    }

    @Test func skipOnStep3RegistersWhatTheSwitchShowed() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        let tour = await toStep3(h)
        tour.skip(h.model)
        #expect(h.loginItemSets == [true])
        #expect(h.preferences.launchAtLoginIntent == true)
    }

    /// A tour skipped before step 3 never showed the switch: the system's state is taken,
    /// as at any launch, and nothing is registered.
    @Test(arguments: [WelcomeTour.Step.welcome, .folder])
    func skipBeforeStep3KeepsTheSystemsState(at step: WelcomeTour.Step) throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        WelcomeTour(step: step).skip(h.model)
        #expect(h.loginItemSets.isEmpty)
        #expect(h.loginReconciles == 1)
        #expect(h.preferences.launchAtLoginIntent == false)
    }

    /// A replayed tour shows and keeps the stored choice.
    @Test func aReplayedTourKeepsTheStoredChoice() async throws {
        let h = try ModelHarness(onboardingShown: true)
        defer { h.tearDown() }
        h.preferences.launchAtLoginIntent = false
        h.model.launch()
        h.model.replayOnboarding()
        #expect(!h.model.launchAtLogin)
        var tour = WelcomeTour(step: .tidy)
        tour.advance(h.model) // Done
        #expect(h.loginItemSets.isEmpty)
        #expect(h.preferences.launchAtLoginIntent == false)
    }

    @Test(arguments: WelcomeTour.Step.allCases)
    func skipRecordsTheTourAndStartsWatching(at step: WelcomeTour.Step) async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        let tour = WelcomeTour(step: step)
        #expect(!h.preferences.onboardingShown)
        tour.skip(h.model)
        #expect(h.preferences.onboardingShown)
        // As launch() would at the next start.
        #expect(h.model.isWatching)
        #expect(await eventually { await h.model.watchedFolder?.path == h.folder.path })
    }

    @Test func turnOnRetentionConfirmsThePreviewedFolder() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        #expect(await h.start())
        #expect(!h.preferences.retention.enabled, "off on a fresh install")
        h.model.refreshPreview()
        #expect(await eventually { await h.model.retentionPreview?.success != nil })
        #expect(await h.model.turnOnRetention())
        #expect(h.preferences.retention.enabled)
        #expect(h.preferences.retention.days == 30)
        #expect(h.preferences.retention.confirmed == ConfirmedFolder.of(h.folder))
        #expect(!h.preferences.onboardingShown)
    }

    @Test func turnOnRetentionNeedsAPreview() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        #expect(await h.start())
        #expect(await !h.model.turnOnRetention())
        #expect(!h.preferences.retention.enabled)
        #expect(h.preferences.retention.confirmed == nil)
    }

    /// Step 3's period is a choice (Addendum A7): picking one in the sentence's pop-up drives
    /// the live preview above it, with retention still off.
    @Test func tourPeriodPickerDrivesPreview() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        let date = Date().addingTimeInterval(-20 * RT.day)
        let url = try Fixtures.write(named: "Twenty days.png", in: h.folder, created: date, modified: date)
        await h.ledger.adopt([try #require(CaptureFile.inspect(url))])
        #expect(await h.start())
        h.model.refreshPreview()
        #expect(await eventually { await h.model.retentionPreview?.success?.days == 30 })
        #expect(h.model.retentionPreview?.success?.expired.isEmpty == true)

        #expect(RetentionPeriod.of(days: 30, customRequested: false) == .preset(30))
        #expect(!RetentionPeriod.choose(.preset(14), preferences: h.preferences))
        #expect(await eventually { await h.model.retentionPreview?.success?.days == 14 })
        #expect(h.model.retentionPreview?.success?.expired.count == 1)
        #expect(!h.preferences.retention.enabled, "choosing a period does not turn retention on")

        // Custom keeps the days and shows the stepper.
        #expect(RetentionPeriod.choose(.custom, preferences: h.preferences))
        #expect(h.preferences.retention.days == 14)
        #expect(RetentionPeriod.of(days: 14, customRequested: true) == .custom)
        #expect(RetentionPeriod.of(days: 45, customRequested: false) == .custom)
    }

    /// Try it's success check bounces once per copy, on the copy itself (the count of copies
    /// goes up in the same step as the menu bar flash starts), only when the result shows,
    /// never with Reduce Motion. Reopening the popover changes no count, so it never replays.
    @Test func trySuccessBouncesOncePerCopy() {
        #expect(TrySuccessMotion.bounces(copiesBefore: 0, copiesNow: 1, showsResult: true, reduceMotion: false))
        #expect(TrySuccessMotion.bounces(copiesBefore: 1, copiesNow: 2, showsResult: true, reduceMotion: false),
                "a second copy in the tour bounces again")
        #expect(!TrySuccessMotion.bounces(copiesBefore: 1, copiesNow: 1, showsResult: true, reduceMotion: false),
                "no copy: the popover reappearing, an attention clearing")
        #expect(!TrySuccessMotion.bounces(copiesBefore: 0, copiesNow: 1, showsResult: false, reduceMotion: false))
        #expect(!TrySuccessMotion.bounces(copiesBefore: 0, copiesNow: 1, showsResult: true, reduceMotion: true))
        // It lands as the new card slides in on the menu bar line.
        let delay = Double(Design.Motion.successBounceDelay.components.attoseconds) / 1e18
            + Double(Design.Motion.successBounceDelay.components.seconds)
        #expect(Peg.Beat.slideIn.contains(delay))
        #expect(Design.Motion.successBounceSpeed > 1, "faster than the system bounce, so it stays short")
    }

    /// The copy count the bounce follows goes up in the same main-actor step as the flash
    /// starts and the result appears.
    @Test func copyCountFlashAndResultChangeTogether() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        var tour = WelcomeTour(step: .folder)
        tour.advance(h.model)
        #expect(await eventually { await h.model.watchedFolder != nil })
        #expect(tour.tryState(h.model) == .waiting)
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.preferences.totals.copied == 1 })
        #expect(h.model.flashPhase > 0)
        if case .copied = tour.tryState(h.model) {} else { Issue.record("the result shows with the count") }
    }
}
