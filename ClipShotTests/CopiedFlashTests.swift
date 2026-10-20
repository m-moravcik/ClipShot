import Foundation
import Testing
@testable import ClipShot

struct CopiedFlashTests {
    @Test func idleUntilRestarted() {
        var flash = CopiedFlash()
        #expect(flash.tick() == 0)
    }

    @Test func runsThroughPhasesAndEndsAtZeroAfterFifteenTicks() {
        var flash = CopiedFlash()
        flash.restart()
        var phases: [Int] = []
        for _ in 0..<CopiedFlash.steps { phases.append(flash.tick()) }
        #expect(phases == Array(1...14) + [0])
        #expect(flash.tick() == 0)
    }

    @Test func restartMidFlashResetsToPhaseOne() {
        var flash = CopiedFlash()
        flash.restart()
        for _ in 0..<7 { _ = flash.tick() }
        flash.restart()
        #expect(flash.tick() == 1)
    }

    @Test func opacityCurve() {
        #expect(CopiedFlash.opacity(phase: 0) == 0)
        #expect(CopiedFlash.opacity(phase: 15) == 0)
        let fadeIn = (1...3).map { CopiedFlash.opacity(phase: $0) }
        #expect(fadeIn == fadeIn.sorted() && fadeIn.allSatisfy { $0 > 0 && $0 < 1 })
        for p in 4...11 { #expect(CopiedFlash.opacity(phase: p) == 1) }
        let fadeOut = (12...15).map { CopiedFlash.opacity(phase: $0) }
        #expect(fadeOut == fadeOut.sorted(by: >) && fadeOut.dropLast().allSatisfy { $0 > 0 && $0 < 1 })
        #expect(abs(CopiedFlash.opacity(phase: 13) - 0.5) < 1e-9)
    }

    /// Reduce Motion: one plain hold, drawn at once, that the single timer tick ends.
    @Test func reduceMotionIsOneHoldEndedByOneTick() {
        #expect(abs(CopiedFlash.holdDuration - CopiedFlash.interval * Double(CopiedFlash.steps - 1)) < 1e-9)
        #expect(CopiedFlash(reduceMotion: true).timerInterval == CopiedFlash.holdDuration)
        #expect(CopiedFlash().timerInterval == CopiedFlash.interval)
        var flash = CopiedFlash(reduceMotion: true)
        flash.restart()
        let hold = flash.tick()
        #expect(hold > 0)
        #expect(CopiedFlash.opacity(phase: hold, reduceMotion: true) == 1)
        let last = flash.tick()
        #expect(last == 0)
        #expect(CopiedFlash.opacity(phase: last, reduceMotion: true) == 0)
        #expect(flash.tick() == 0)
    }
}
