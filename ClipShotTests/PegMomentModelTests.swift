import Foundation
import Testing
@testable import ClipShot

/// When the model plays Peg's moments: on real state changes only, once, on the frame
/// timer that stops with them, never cutting a copy short, and not at all with Reduce Motion.
@MainActor
struct PegMomentModelTests {
    /// Something first needs fixing: Peg swings into "!" once. A second problem while "!"
    /// shows plays nothing more, but each new problem still counts for the popover's nod.
    @Test func attentionSwingsOnceWhenSomethingFirstNeedsFixing() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["target"] = "clipboard"
        #expect(await h.start())
        #expect(await eventually { await h.model.attentions.map(\.id) == [Attention.destinationNotFile.id] })
        #expect(h.model.flashMoment == .attention)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.iconState == .attention, "VoiceOver says attention at once")
        #expect(h.model.iconPose == Peg.pose(.idle), "the swing starts from the picture")
        #expect(h.model.attentionArrivals == 1)
        let timer = try #require(h.timer)
        #expect(timer.interval == PegFlash.interval)
        timer.fire(PegMoment.attention.steps - 1)
        #expect(h.model.flashPhase == 0)
        #expect(timer.invalidated, "no timer at rest")
        #expect(h.model.iconPose == Peg.pose(.attention))

        // A second problem: counted, but no second swing.
        h.pasteboard.failing = true
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.attentions.count == 2 })
        #expect(h.model.attentionArrivals == 2)
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.count == 1)
    }

    /// Fixed while Peg still swings: the moment ends at once on the resting pose, its timer
    /// goes, and VoiceOver and the icon agree.
    @Test func attentionClearedMidSwingEndsOnTheRestingPose() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["target"] = "clipboard"
        #expect(await h.start())
        #expect(await eventually { await !h.model.attentions.isEmpty })
        let timer = try #require(h.timer)
        timer.fire(10)
        #expect(h.model.flashMoment == .attention)
        #expect(h.model.flashPhase == 11)
        await h.model.fixDestination()
        #expect(await eventually { await h.model.attentions.isEmpty })
        #expect(h.model.flashPhase == 0)
        #expect(timer.invalidated, "no timer left after the moment ends")
        #expect(h.model.iconState == .idle)
        #expect(h.model.iconPose == Peg.pose(.idle))
        timer.fire(5)
        #expect(h.model.flashPhase == 0, "a late tick of the old timer draws nothing")
    }

    @Test func reduceMotionSwapsToAttentionInOneFrame() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.reduceMotion = true
        h.prefs["target"] = "clipboard"
        #expect(await h.start())
        #expect(await eventually { await !h.model.attentions.isEmpty })
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.isEmpty)
        #expect(h.model.iconPose == Peg.pose(.attention))
    }

    /// A problem that does not stop copying (the retention folder changed): a copy still
    /// plays its animation and says Copied, then the icon returns to "!".
    @Test func copyWhileAttentionPlaysTheCopyThenReturnsToAttention() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.preferences.retention = RT.policy(h.folder)
        #expect(await h.start())
        #expect(await h.statusRead())
        let other = h.home.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.prefs["location"] = other.path
        #expect(await eventually { await !h.model.attentions.isEmpty })
        #expect(await eventually { await h.model.watchedFolder?.path == other.path })
        h.timer?.fire(PegMoment.attention.steps)
        #expect(h.model.flashPhase == 0)

        try Fixtures.write(named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 16), in: other)
        #expect(await eventually { await h.preferences.totals.copied == 1 })
        #expect(h.model.flashMoment == .copied)
        #expect(h.model.iconState == .copied)
        let timer = try #require(h.timer)
        timer.fire(PegFlash.steps - 2)
        #expect(h.model.flashPhase == PegFlash.steps - 1)
        #expect(h.model.iconPose == Peg.pose(.attention), "the last frame is the attention pose")
        timer.fire()
        #expect(h.model.flashPhase == 0)
        #expect(h.model.iconState == .attention)
        #expect(h.model.iconPose == Peg.pose(.attention))
    }

    /// The switch answers in the menu bar: pause, then resume, each once, each ending at rest.
    @Test func pauseAndResumePlayOnTheSwitch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.preferences.copyEnabled = false
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        #expect(h.model.iconState == .paused)
        let pause = try #require(h.timer)
        pause.fire(PegMoment.pause.steps - 1)
        #expect(h.model.flashPhase == 0)
        #expect(pause.invalidated)
        #expect(h.model.iconPose == Peg.pose(.paused))

        h.preferences.copyEnabled = true
        #expect(await eventually { await h.model.flashMoment == .resume ? h.model.flashPhase > 0 : false })
        #expect(h.model.iconPose == Peg.pose(.paused), "resume starts from the dashed card")
        let resume = try #require(h.timer)
        resume.fire(PegMoment.resume.steps - 1)
        #expect(h.model.flashPhase == 0)
        #expect(h.model.iconPose == Peg.pose(.idle))
        #expect(h.timers.count == 2)
    }

    /// Switching copying off during a copy does not cut the copy short: it ends on the
    /// dashed card instead of the picture.
    @Test func aCopyEndsOnTheDashedCardWhenPausedDuringIt() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.flashPhase == 1 })
        let timer = try #require(h.timer)
        timer.fire(5)
        h.preferences.copyEnabled = false
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        #expect(h.model.flashMoment == .copied)
        #expect(h.model.flashPhase == 6)
        timer.fire(PegFlash.steps - 6)
        #expect(h.model.flashPhase == 0)
        #expect(h.model.iconPose == Peg.pose(.paused))
        #expect(h.timers.count == 1)
    }

    /// While "!" shows, pausing changes nothing in the menu bar; Reduce Motion plays no
    /// pause either.
    @Test func noPauseMomentUnderAttentionOrReduceMotion() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["target"] = "clipboard"
        #expect(await h.start())
        #expect(await eventually { await !h.model.attentions.isEmpty })
        h.timer?.fire(PegMoment.attention.steps)
        h.preferences.copyEnabled = false
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.count == 1)

        let calm = try ModelHarness()
        defer { calm.tearDown() }
        calm.reduceMotion = true
        #expect(await calm.start())
        calm.preferences.copyEnabled = false
        #expect(await eventually { await !calm.model.copyEnabledInPipeline })
        #expect(calm.model.flashPhase == 0)
        #expect(calm.timers.isEmpty)
        #expect(calm.model.iconPose == Peg.pose(.paused))
    }
}
