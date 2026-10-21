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

    /// Which moment replaces which: among copy, release and grip the latest wins; a change of
    /// state replaces anything but a copy and gives way to none of the user's own actions; the
    /// squeeze replaces only a squeeze and cuts nothing else short.
    @Test(arguments: PegMoment.allCases)
    func precedence(_ next: PegMoment) {
        let states: [PegMoment] = [.attention, .pause, .resume]
        let actions: [PegMoment] = [.copied, .release, .grip]
        for playing in PegMoment.allCases {
            let expected: Bool = switch next {
            case .copied, .release, .grip: actions.contains(playing) || playing == .squeeze
                || (next == .copied && states.contains(playing))
            case .attention, .pause, .resume: playing != .copied
            case .squeeze: playing == .squeeze
            }
            #expect(next.replaces(playing) == expected, "\(next) over \(playing)")
        }
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

    /// The copy's swap (peg opening, old card dropping, new card sliding in) is 1.6-1.8 times
    /// as slow as the first cut (0.14, 0.3 and 0.56 s long, the slide over by 0.76 s), so the
    /// old card is seen leaving before the new one lands; the clamp, swing and check keep
    /// their lengths, the resume's bite is unchanged, and the copy still ends at rest.
    @Test func theSwapIsSlowedAndThePinKeepsItsPace() {
        func length(_ beat: ClosedRange<Double>) -> Double { beat.upperBound - beat.lowerBound }
        let slowed = [
            length(Peg.Beat.pegOpen) / 0.14, length(Peg.Beat.oldDrop) / 0.3, length(Peg.Beat.slideIn) / 0.56,
            Peg.Beat.slideIn.upperBound / 0.76,
        ]
        for ratio in slowed { #expect(ratio >= 1.6 && ratio <= 1.8, "\(ratio)x") }
        #expect(Peg.Beat.oldDrop.upperBound < Peg.Beat.slideIn.upperBound - 0.5, "the old card is gone well before the new one lands")
        let kept: [(ClosedRange<Double>, Double)] = [
            (Peg.Beat.pegShut, 0.14), (Peg.Beat.clampBounce, 0.36), (Peg.Beat.swing, 1.06), (Peg.Beat.bob, 0.96),
            (Peg.Beat.develop, 0.3), (Peg.Beat.checkOn, 0.24), (Peg.Beat.checkOff, 0.1), (Peg.Beat.drain, 0.26),
        ]
        for (beat, seconds) in kept { #expect(abs(length(beat) - seconds) < 1e-9) }
        #expect(Peg.Beat.checkOff.lowerBound - Peg.Beat.checkOn.upperBound >= 0.5, "the check still holds")
        #expect(abs(Peg.ResumeBeat.pegShut.lowerBound - 0.38) < 1e-9 && abs(Peg.ResumeBeat.pegShut.upperBound - 0.52) < 1e-9)
        #expect(abs(Peg.ResumeBeat.clampBounce.lowerBound - 0.5) < 1e-9 && abs(Peg.ResumeBeat.clampBounce.upperBound - 0.86) < 1e-9)
        #expect(Peg.Beat.drain.upperBound <= PegFlash.time(phase: PegFlash.steps - 1), "at rest by the last frame")
        #expect(PegFlash.duration <= 3)
    }

    @Test func idleUntilRestarted() {
        var flash = PegFlash()
        #expect(flash.tick() == 0)
    }

    /// 2.9 s at 30 fps: 87 frames, then the tick that ends it; never longer than 3 s.
    @Test func timingComesFromTheMotionTokens() {
        #expect(PegFlash.interval == 1 / Design.Motion.menuBarFrameRate)
        #expect(PegFlash.duration == Design.Motion.menuBarCopy)
        #expect(PegFlash.holdDuration == Design.Motion.menuBarHold)
        #expect(PegFlash.steps == 88)
        #expect(PegFlash.duration <= 3)
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
