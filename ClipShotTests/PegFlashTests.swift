import Foundation
import Testing
@testable import ClipShot

struct PegFlashTests {
    /// The preview's Copied badge and Try it's check bounce as Peg's clamp bites, derived
    /// from the beat, so a retime of Peg keeps all three in step.
    @Test func bouncesLandWithThePegClamp() {
        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        #expect(abs(seconds(Design.Motion.pegged) - Peg.Beat.clampBounce.lowerBound) < 0.001)
        #expect(Design.Motion.badgeDelay == Design.Motion.pegged)
        #expect(Design.Motion.successBounceDelay == Design.Motion.pegged)
    }

    /// Every moment's length comes from its token, and is a whole number of frames.
    @Test func momentsTimeFromTheMotionTokens() {
        #expect(PegMoment.copied.duration == Design.Motion.menuBarCopy)
        #expect(PegMoment.attention.duration == Design.Motion.menuBarAttention)
        #expect(PegMoment.pause.duration == Design.Motion.menuBarPause)
        #expect(PegMoment.resume.duration == Design.Motion.menuBarResume)
        for moment in [PegMoment.attention, .pause, .resume] {
            #expect(abs(Double(moment.steps - 1) * PegFlash.interval - moment.duration) < 1e-9)
        }
        // The switch's answers are short: the user is looking at the popover.
        for moment in [PegMoment.pause, .resume] {
            #expect(moment.duration < 1, "\(moment) is a small moment, under a second")
        }
        // Attention is unsolicited: a menu bar moment, long enough to catch at a glance, and
        // no longer than the copy.
        #expect(PegMoment.attention.duration >= 1.8 && PegMoment.attention.duration <= PegMoment.copied.duration)
    }

    /// The user's own actions, seen in place: release about 1.0-1.3 s, grip 0.8-1.0 s, the
    /// squeeze 180-250 ms, all shorter than the copy, each a whole number of frames.
    @Test func userMomentsTimeFromTheirTokens() {
        #expect(PegMoment.release.duration == Design.Motion.menuBarRelease)
        #expect(PegMoment.grip.duration == Design.Motion.menuBarGrip)
        #expect(PegMoment.squeeze.duration == Design.Motion.menuBarSqueeze)
        #expect((1.0...1.3).contains(PegMoment.release.duration))
        #expect((0.8...1.0).contains(PegMoment.grip.duration))
        #expect((0.18...0.25).contains(PegMoment.squeeze.duration))
        for moment in [PegMoment.release, .grip, .squeeze] {
            #expect(moment.duration < PegMoment.copied.duration)
            #expect(abs(Double(moment.steps - 1) * PegFlash.interval - moment.duration) < 1e-9)
        }
        #expect(Design.Motion.menuBarHandoff < PegMoment.squeeze.duration, "a hand-off fits the shortest moment")
    }

    /// copy > attention, pause, resume > release, grip > squeeze.
    @Test func precedence() {
        #expect(PegMoment.copied.rank > PegMoment.attention.rank)
        #expect(PegMoment.attention.rank == PegMoment.pause.rank && PegMoment.pause.rank == PegMoment.resume.rank)
        #expect(PegMoment.attention.rank > PegMoment.release.rank)
        #expect(PegMoment.release.rank == PegMoment.grip.rank)
        #expect(PegMoment.grip.rank > PegMoment.squeeze.rank)
    }

    /// Reduce Motion: the copy, a release and a grip are one hold each, as long as the copy's
    /// hold or the moment itself; the others do not play.
    @Test func reduceMotionHolds() {
        #expect(PegMoment.copied.reduceMotionHold == Design.Motion.menuBarHold)
        #expect(PegMoment.release.reduceMotionHold == Design.Motion.menuBarRelease)
        #expect(PegMoment.grip.reduceMotionHold == Design.Motion.menuBarGrip)
        for moment in [PegMoment.attention, .pause, .resume, .squeeze] {
            #expect(moment.reduceMotionHold == nil)
        }
        for moment in [PegMoment.copied, .release, .grip] {
            var flash = PegFlash(moment, reduceMotion: true)
            #expect(flash.timerInterval == moment.reduceMotionHold)
            flash.restart()
            #expect(flash.tick() == 1)
            #expect(flash.tick() == 0)
        }
    }

    @Test(arguments: PegMoment.allCases)
    func everyMomentRunsThroughItsFramesAndEnds(_ moment: PegMoment) {
        var flash = PegFlash(moment)
        flash.restart()
        var phases: [Int] = []
        for _ in 0..<moment.steps { phases.append(flash.tick()) }
        #expect(phases == Array(1..<moment.steps) + [0])
        #expect(flash.tick() == 0)
    }

    @Test func idleUntilRestarted() {
        var flash = PegFlash()
        #expect(flash.tick() == 0)
    }

    /// 2.4 s at 30 fps: 72 frames, then the tick that ends it.
    @Test func timingComesFromTheMotionTokens() {
        #expect(PegFlash.interval == 1 / Design.Motion.menuBarFrameRate)
        #expect(PegFlash.duration == Design.Motion.menuBarCopy)
        #expect(PegFlash.holdDuration == Design.Motion.menuBarHold)
        #expect(PegFlash.steps == 73)
        #expect(abs(Double(PegFlash.steps - 1) * PegFlash.interval - PegFlash.duration) < 1e-9,
                "the tick that ends the animation comes `duration` after the first frame")
        #expect(PegFlash.tolerance > 0 && PegFlash.tolerance < PegFlash.interval / 2,
                "the timer may be coalesced by part of a frame, never by a whole one")
    }

    @Test func runsThroughEveryFrameAndEndsAtZero() {
        var flash = PegFlash()
        flash.restart()
        var phases: [Int] = []
        for _ in 0..<PegFlash.steps { phases.append(flash.tick()) }
        #expect(phases == Array(1..<PegFlash.steps) + [0])
        #expect(flash.tick() == 0)
    }

    @Test func restartMidFlashResetsToPhaseOne() {
        var flash = PegFlash()
        flash.restart()
        for _ in 0..<20 { _ = flash.tick() }
        flash.restart()
        #expect(flash.tick() == 1)
    }

    @Test func phasesMapToTimesFromTheStart() {
        #expect(PegFlash.time(phase: 1) == 0)
        #expect(abs(PegFlash.time(phase: 31) - 1) < 1e-9)
        let last = PegFlash.time(phase: PegFlash.steps - 1)
        #expect(last < PegFlash.duration && last > PegFlash.duration - PegFlash.interval * 1.5)
    }

    /// Reduce Motion: one plain hold of the copied pose, drawn at once, that the single timer
    /// tick ends.
    @Test func reduceMotionIsOneHoldEndedByOneTick() {
        #expect(PegFlash(reduceMotion: true).timerInterval == PegFlash.holdDuration)
        #expect(PegFlash().timerInterval == PegFlash.interval)
        var flash = PegFlash(reduceMotion: true)
        flash.restart()
        let hold = flash.tick()
        #expect(hold > 0)
        #expect(Peg.pose(state: .copied, phase: hold, reduceMotion: true) == Peg.pose(.copied))
        #expect(flash.tick() == 0)
        #expect(flash.tick() == 0)
    }
}
