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
}
