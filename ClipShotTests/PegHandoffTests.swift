import AppKit
import Testing
@testable import ClipShot

/// A moment that replaces one still playing starts exactly where the icon was and ends
/// exactly at rest: nothing jumps, whichever moment it cuts into and wherever.
struct PegHandoffTests {
    struct Cut: Sendable, CustomTestStringConvertible {
        let running: PegMoment
        let phase: Int
        let next: PegMoment
        var from: StatusIconState = .idle
        var to: StatusIconState = .idle
        var testDescription: String { "\(next) over \(running) at phase \(phase), \(from) -> \(to)" }
    }

    static let cuts: [Cut] = [
        // Copy outranks everything: from a release mid-drop, a grip, a squeeze, a swing.
        Cut(running: .release, phase: 8, next: .copied),
        Cut(running: .release, phase: 20, next: .copied),
        Cut(running: .grip, phase: 3, next: .copied),
        Cut(running: .grip, phase: 14, next: .copied),
        Cut(running: .squeeze, phase: 3, next: .copied),
        Cut(running: .attention, phase: 20, next: .copied, from: .idle, to: .attention),
        // A copy over a copy: before its new card slid in, and while it swings.
        Cut(running: .copied, phase: 4, next: .copied),
        Cut(running: .copied, phase: 40, next: .copied),
        // A change of state over the user's own actions.
        Cut(running: .release, phase: 10, next: .attention, from: .idle, to: .attention),
        Cut(running: .grip, phase: 10, next: .attention, from: .idle, to: .attention),
        Cut(running: .release, phase: 30, next: .pause, from: .idle, to: .paused),
        Cut(running: .squeeze, phase: 2, next: .attention, from: .idle, to: .attention),
        Cut(running: .pause, phase: 6, next: .attention, from: .idle, to: .attention),
        // Release and grip over each other, and over the squeeze.
        Cut(running: .release, phase: 12, next: .grip),
        Cut(running: .release, phase: 5, next: .release),
        Cut(running: .grip, phase: 4, next: .release),
        Cut(running: .grip, phase: 12, next: .grip),
        Cut(running: .squeeze, phase: 2, next: .release),
        Cut(running: .squeeze, phase: 3, next: .grip),
        Cut(running: .squeeze, phase: 2, next: .squeeze),
    ]

    private static func onShow(_ cut: Cut) -> Peg.Pose {
        Peg.pose(rest: cut.from, moment: cut.running, phase: cut.phase, from: cut.from, reduceMotion: false)
    }

    private static func pose(_ cut: Cut, phase: Int, handoff: Peg.Pose?) -> Peg.Pose {
        Peg.pose(rest: cut.to, moment: cut.next, phase: phase, from: cut.from, reduceMotion: false, handoff: handoff)
    }

    private static func pixels(_ pose: Peg.Pose) throws -> [UInt8] {
        try GlyphInk.alpha(#require(GlyphInk.unclipped(pose, pad: 8)))
    }

    /// The largest difference in coverage between two drawings, 0...255.
    private static func difference(_ a: Peg.Pose, _ b: Peg.Pose) throws -> Int {
        zip(try pixels(a), try pixels(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test(arguments: cuts)
    func startsWhereTheIconWasAndEndsAtRest(_ cut: Cut) throws {
        let shown = Self.onShow(cut)
        let first = Self.pose(cut, phase: 1, handoff: shown)
        #expect(try Self.difference(first, shown) <= 2, "the first frame draws what was on show")
        let last = Self.pose(cut, phase: cut.next.steps - 1, handoff: shown)
        #expect(last == Peg.pose(cut.to), "the last frame is the resting pose")
        #expect(Self.pose(cut, phase: 0, handoff: shown) == Peg.pose(cut.to))
    }

    /// The hand-off is what removes the jump: started from rest instead, these cuts would
    /// change the picture at once.
    @Test func withoutTheHandoffTheseCutsWouldJump() throws {
        for cut in [Self.cuts[0], Self.cuts[5], Self.cuts[8], Self.cuts[13]] {
            let shown = Self.onShow(cut)
            #expect(try Self.difference(Self.pose(cut, phase: 1, handoff: nil), shown) > 100, "\(cut.testDescription)")
        }
    }

    /// Past the hand-off the moment runs its own course: the frames are the ones it plays
    /// from rest, except the card it carries on from the cut (copy, release, grip).
    @Test(arguments: cuts)
    func afterTheHandoffTheMomentRunsItsOwnCourse(_ cut: Cut) {
        let shown = Self.onShow(cut)
        let after = Int((Design.Motion.menuBarHandoff * PegFlash.frameRate).rounded(.up)) + 2
        for phase in after..<cut.next.steps {
            let handed = Self.pose(cut, phase: phase, handoff: shown)
            let own = Self.pose(cut, phase: phase, handoff: nil)
            #expect(handed.pegLift == own.pegLift && handed.sag == own.sag && handed.pegPinch == own.pegPinch,
                    "phase \(phase)")
            switch cut.next {
            case .pause, .resume, .squeeze:
                #expect(handed.card == own.card, "phase \(phase)")
            case .attention:
                // Its picture, dashes and mark turn into "!" from the card on show.
                #expect(handed.card.angle == own.card.angle && handed.card.dy == own.card.dy, "phase \(phase)")
            case .copied, .release, .grip:
                break
            }
        }
    }

    /// Every frame of a cut stays a template image of the canvas's size.
    @MainActor
    @Test(arguments: cuts)
    func everyFrameIsATemplateOfTheCanvasSize(_ cut: Cut) {
        let shown = Self.onShow(cut)
        for phase in 1..<cut.next.steps {
            let image = Peg.image(Self.pose(cut, phase: phase, handoff: shown))
            #expect(image.isTemplate)
            #expect(image.size == Peg.canvas)
        }
    }

    /// The top of the frame is never crossed, during the hand-off either.
    @Test(arguments: cuts)
    func neverRisesPastTheTop(_ cut: Cut) throws {
        let shown = Self.onShow(cut)
        let pad: CGFloat = 8
        for phase in 1..<cut.next.steps {
            let image = try #require(GlyphInk.unclipped(Self.pose(cut, phase: phase, handoff: shown), pad: pad))
            let box = try #require(GlyphInk.inkBox(image))
            #expect(box.minY >= Int(pad * GlyphInk.scale) - 1, "phase \(phase)")
        }
    }
}
