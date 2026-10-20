import AppKit
import Testing
@testable import ClipShot

/// Peg's moments as drawn: each starts where the icon rested and ends exactly on the state
/// it settles in, moves in between, and every frame fits the status item.
struct PegMomentTests {
    struct Play: Sendable, CustomTestStringConvertible {
        let moment: PegMoment
        let from: StatusIconState
        let to: StatusIconState
        var testDescription: String { "\(moment) \(from) -> \(to)" }
    }

    static let plays: [Play] = [
        Play(moment: .copied, from: .idle, to: .idle),
        Play(moment: .copied, from: .paused, to: .paused),
        Play(moment: .copied, from: .attention, to: .attention),
        Play(moment: .copied, from: .idle, to: .attention),
        Play(moment: .attention, from: .idle, to: .attention),
        Play(moment: .attention, from: .paused, to: .attention),
        Play(moment: .pause, from: .idle, to: .paused),
        Play(moment: .resume, from: .paused, to: .idle),
    ]

    private static func pose(_ play: Play, phase: Int, reduceMotion: Bool = false) -> Peg.Pose {
        Peg.pose(rest: play.to, moment: play.moment, phase: phase, from: play.from, reduceMotion: reduceMotion)
    }

    private static func frames(_ play: Play) -> [Peg.Pose] {
        (1..<play.moment.steps).map { pose(play, phase: $0) }
    }

    /// The copy starts with an empty line (the new card is still off to the side, the old one
    /// about to drop); every other moment starts on the pose the icon rested in. All end on
    /// the resting pose, exactly, so nothing jumps when the timer stops.
    @Test(arguments: plays)
    func startsAndEndsAtRest(_ play: Play) throws {
        let frames = Self.frames(play)
        let last = try #require(frames.last)
        #expect(last == Peg.pose(play.to), "last frame")
        #expect(Self.pose(play, phase: 0) == Peg.pose(play.to), "phase 0 is the resting pose")
        let first = try #require(frames.first)
        if play.moment == .copied {
            #expect(first.old?.angle == Peg.restingCard(play.from).angle, "the card that drops is the old one")
            #expect(first.old?.dash == Peg.restingCard(play.from).dash)
            #expect(first.card.opacity == 0)
        } else {
            #expect(first == Peg.pose(play.from), "first frame")
        }
        let moving = zip(frames, frames.dropFirst()).filter { $0 != $1 }.count
        #expect(moving >= frames.count / 2, "\(moving) of \(frames.count - 1) frames move")
    }

    /// The swing goes clearly past the attention tilt before it settles, and the "!" is in.
    @Test func attentionSwingsPastItsTiltOnce() {
        let play = Play(moment: .attention, from: .idle, to: .attention)
        let angles = Self.frames(play).map(\.card.angle)
        let peak = angles.max() ?? 0
        #expect(peak > Peg.attentionAngle * 1.6 && peak < Peg.attentionAngle * 2.3, "peak \(peak) degrees")
        let mid = Self.pose(play, phase: Int((Peg.AttentionBeat.mark.upperBound * PegFlash.frameRate).rounded()) + 1)
        #expect(mid.card.bang == 1 && mid.card.picture == 0)
    }

    /// Pausing breaks the outline from the bottom: halfway, the top of the card is solid and
    /// the bottom dashed.
    @Test func pauseBreaksTheOutlineFromTheBottom() throws {
        let half = Peg.pausePose(at: (Peg.PauseBeat.breakUp.lowerBound + Peg.PauseBeat.breakUp.upperBound) / 2)
        #expect(half.card.dash > 0.3 && half.card.dash < 0.7)
        let image = try #require(GlyphInk.unclipped(half, pad: 0))
        let solid = try #require(GlyphInk.unclipped(Peg.pose(.idle), pad: 0))
        let dashed = try #require(GlyphInk.unclipped(Peg.pose(.paused), pad: 0))
        // The card's left edge, high up and low down: solid like idle above, gapped below.
        let x = Int(Peg.card.minX * GlyphInk.scale)
        let top = Int((Peg.card.minY + 2) * GlyphInk.scale)...Int((Peg.card.midY - 1) * GlyphInk.scale)
        let bottom = Int((Peg.card.maxY - 3) * GlyphInk.scale)...Int((Peg.card.maxY - 1) * GlyphInk.scale)
        #expect(GlyphInk.column(solid, x: x, rows: bottom) != GlyphInk.column(dashed, x: x, rows: bottom),
                "the rows compared tell solid from dashed")
        #expect(GlyphInk.column(image, x: x, rows: top) == GlyphInk.column(solid, x: x, rows: top))
        #expect(GlyphInk.column(image, x: x, rows: bottom) == GlyphInk.column(dashed, x: x, rows: bottom))
    }

    /// Reduce Motion: the copy is the copied pose held; every other moment is its end state.
    @Test(arguments: plays)
    func reduceMotionDoesNotMove(_ play: Play) {
        for phase in 1..<play.moment.steps {
            let pose = Self.pose(play, phase: phase, reduceMotion: true)
            #expect(pose == Peg.pose(play.moment == .copied ? .copied : play.to), "phase \(phase)")
        }
    }

    /// Every frame, drawn with room to spare, stays in the 22 x 16 pt frame (once the copy's
    /// new card has slid in), within a pixel of anti-aliasing, and the peg never rises past
    /// its top.
    @Test(arguments: plays)
    func everyFrameFitsTheCanvas(_ play: Play) throws {
        let pad: CGFloat = 8
        let scale = GlyphInk.scale
        let frame = (minX: Int(pad * scale), minY: Int(pad * scale),
                     maxX: Int((pad + Peg.canvas.width) * scale) - 1, maxY: Int((pad + Peg.canvas.height) * scale) - 1)
        for phase in 1..<play.moment.steps {
            let t = PegFlash.time(phase: phase)
            let pose = Self.pose(play, phase: phase)
            let image = try #require(GlyphInk.unclipped(pose, pad: pad))
            let box = try #require(GlyphInk.inkBox(image))
            #expect(box.minY >= frame.minY - 1, "t \(t): ink \(frame.minY - box.minY) px above the frame")
            if play.moment == .copied, t < Peg.Beat.slideIn.upperBound { continue }
            if let old = pose.old, old.opacity > 0, play.moment == .copied, t < Peg.Beat.oldDrop.upperBound { continue }
            #expect(box.minX >= frame.minX - 1 && box.maxX <= frame.maxX + 1, "t \(t): ink outside the frame's sides")
            #expect(box.maxY <= frame.maxY + 1, "t \(t): ink \(box.maxY - frame.maxY) px below the frame")
        }
    }

    /// Every frame is a template image of the status item's size.
    @MainActor
    @Test(arguments: plays)
    func everyFrameIsATemplateOfTheCanvasSize(_ play: Play) {
        for pose in Self.frames(play) {
            let image = Peg.image(pose)
            #expect(image.isTemplate)
            #expect(image.size == Peg.canvas)
        }
    }

    /// A large Peg (the tour's) is the same drawing at twice the size.
    @MainActor
    @Test func scaledImageIsTheSameDrawing() {
        let image = Peg.image(Peg.pose(.idle), scale: 2)
        #expect(image.isTemplate)
        #expect(image.size == CGSize(width: Peg.canvas.width * 2, height: Peg.canvas.height * 2))
    }
}
