import Foundation
import Testing
@testable import ClipShot

struct CopiedFlashTests {
    @Test func idleUntilRestarted() {
        var flash = CopiedFlash()
        #expect(flash.tick() == 0)
    }

    /// 1.5 s at 30 fps: 45 frames, then the tick that ends it.
    @Test func timingComesFromTheMotionTokens() {
        #expect(CopiedFlash.interval == 1 / Design.Motion.menuBarFrameRate)
        #expect(CopiedFlash.duration == Design.Motion.menuBarCopy)
        #expect(CopiedFlash.holdDuration == Design.Motion.menuBarHold)
        #expect(CopiedFlash.steps == 46)
        #expect(abs(Double(CopiedFlash.steps - 1) * CopiedFlash.interval - CopiedFlash.duration) < 1e-9,
                "the tick that ends the animation comes `duration` after the first frame")
        #expect(CopiedFlash.tolerance > 0 && CopiedFlash.tolerance < CopiedFlash.interval / 2,
                "the timer may be coalesced by part of a frame, never by a whole one")
    }

    @Test func runsThroughEveryFrameAndEndsAtZero() {
        var flash = CopiedFlash()
        flash.restart()
        var phases: [Int] = []
        for _ in 0..<CopiedFlash.steps { phases.append(flash.tick()) }
        #expect(phases == Array(1..<CopiedFlash.steps) + [0])
        #expect(flash.tick() == 0)
    }

    @Test func restartMidFlashResetsToPhaseOne() {
        var flash = CopiedFlash()
        flash.restart()
        for _ in 0..<20 { _ = flash.tick() }
        flash.restart()
        #expect(flash.tick() == 1)
    }

    @Test func phasesMapToTimesFromTheStart() {
        #expect(CopiedFlash.time(phase: 1) == 0)
        #expect(abs(CopiedFlash.time(phase: 31) - 1) < 1e-9)
        let last = CopiedFlash.time(phase: CopiedFlash.steps - 1)
        #expect(last < CopiedFlash.duration && last > CopiedFlash.duration - CopiedFlash.interval * 1.5)
    }

    /// Reduce Motion: one plain hold of the copied pose, drawn at once, that the single timer
    /// tick ends.
    @Test func reduceMotionIsOneHoldEndedByOneTick() {
        #expect(CopiedFlash(reduceMotion: true).timerInterval == CopiedFlash.holdDuration)
        #expect(CopiedFlash().timerInterval == CopiedFlash.interval)
        var flash = CopiedFlash(reduceMotion: true)
        flash.restart()
        let hold = flash.tick()
        #expect(hold > 0)
        #expect(Peg.pose(state: .copied, phase: hold, reduceMotion: true) == Peg.pose(.copied))
        #expect(flash.tick() == 0)
        #expect(flash.tick() == 0)
    }
}
