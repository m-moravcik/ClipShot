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
        Play(moment: .release, from: .idle, to: .idle),
        Play(moment: .release, from: .paused, to: .paused),
        Play(moment: .release, from: .attention, to: .attention),
        Play(moment: .grip, from: .idle, to: .idle),
        Play(moment: .grip, from: .paused, to: .paused),
        Play(moment: .grip, from: .attention, to: .attention),
        Play(moment: .squeeze, from: .idle, to: .idle),
        Play(moment: .squeeze, from: .paused, to: .paused),
        Play(moment: .squeeze, from: .attention, to: .attention),
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
        } else if play.moment == .grip || play.moment == .release {
            // The card on show is still there, about to fade or drop; the one that rises or
            // comes back is not yet.
            #expect(first.old == Peg.restingCard(play.from), "the card that leaves is the one on show")
            #expect(first.card.opacity == 0)
            #expect(first.sag == 0 && first.pegLift == 0 && first.pegSquash == 1)
            let shown = try #require(GlyphInk.unclipped(Peg.pose(play.from), pad: 0))
            let drawn = try #require(GlyphInk.unclipped(first, pad: 0))
            #expect(GlyphInk.alpha(drawn) == GlyphInk.alpha(shown), "it draws the resting pose")
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

    /// Reduce Motion: the copy is the copied pose held, a release or a grip its key pose
    /// held; every other moment is its end state.
    @Test(arguments: plays)
    func reduceMotionDoesNotMove(_ play: Play) {
        let held: Peg.Pose = switch play.moment {
        case .copied: Peg.pose(.copied)
        case .release: Peg.releaseKeyPose
        case .grip: Peg.gripKeyPose(play.to)
        case .attention, .pause, .resume, .squeeze: Peg.pose(play.to)
        }
        for phase in 1..<play.moment.steps {
            #expect(Self.pose(play, phase: phase, reduceMotion: true) == held, "phase \(phase)")
        }
    }

    /// The key poses say what happened without movement, each with its own silhouette: the
    /// release an empty line under open jaws, the grip the picture under open jaws.
    @Test func keyPosesDifferFromRest() throws {
        let rest = try #require(GlyphInk.unclipped(Peg.pose(.idle), pad: 0))
        let release = try #require(GlyphInk.unclipped(Peg.releaseKeyPose, pad: 0))
        let grip = try #require(GlyphInk.unclipped(Peg.gripKeyPose(.idle), pad: 0))
        #expect(Peg.releaseKeyPose.card.opacity == 0 && Peg.releaseKeyPose.pegLift > 1)
        #expect(Peg.gripKeyPose(.idle).pegLift > 1 && Peg.gripKeyPose(.idle).card.dy > 1)
        #expect(GlyphInk.alpha(release) != GlyphInk.alpha(rest))
        #expect(GlyphInk.alpha(grip) != GlyphInk.alpha(rest))
        #expect(GlyphInk.alpha(grip) != GlyphInk.alpha(release))
    }

    /// Letting go: the card leaves the frame downwards and the line is empty for a beat,
    /// with the jaws shut, before the resting card comes back.
    @Test func releaseDropsTheCardOutAndClosesEmpty() {
        let play = Play(moment: .release, from: .idle, to: .idle)
        let frames = Self.frames(play)
        let lowest = frames.map { $0.old.map { $0.opacity > 0 ? $0.dy : 0 } ?? 0 }.max() ?? 0
        #expect(Peg.card.minY + lowest > Peg.canvas.height * 0.85, "the card falls out of the frame")
        let empty = frames.filter { $0.card.opacity == 0 && $0.old == nil }
        #expect(empty.count >= 4, "a beat of the empty line")
        #expect(empty.contains { $0.pegLift <= 0 }, "the jaws close on nothing")
        #expect(frames.map(\.pegLift).max() ?? 0 >= 1.2, "the jaws open")
    }

    /// Gripping: a picture rises from below into the open jaws, which then clamp with a bite.
    @Test func gripRaisesThePictureIntoTheOpenJaws() {
        let play = Play(moment: .grip, from: .idle, to: .idle)
        let frames = Self.frames(play)
        #expect(frames.contains { $0.card.dy >= Peg.GripBeat.depth * 0.6 && $0.card.opacity > 0 }, "it rises from below")
        let risen = frames.firstIndex { $0.card.dy == 0 && $0.card.opacity == 1 } ?? frames.count
        #expect(frames[..<risen].contains { $0.pegLift > 1 }, "the jaws are open as it rises")
        #expect(frames[risen...].contains { $0.pegLift < 0 }, "the clamp bites past rest")
    }

    /// The squeeze: the handles pressed together and the jaws open about a point, inside
    /// 180-250 ms, then back past rest once and settled.
    @Test func squeezePressesTheHandlesAndOpensTheJawsAPoint() throws {
        let play = Play(moment: .squeeze, from: .idle, to: .idle)
        let frames = Self.frames(play)
        let open = frames.map(\.pegLift).max() ?? 0
        #expect(open > 0.8 && open <= 1.0, "jaws open \(open) pt")
        #expect((frames.map(\.pegPinch).max() ?? 0) > 0.8)
        #expect(frames.contains { $0.pegPinch < 0 }, "springs back past rest")
        #expect(frames.allSatisfy { $0.card == Peg.restingCard(.idle) && $0.sag == 0 }, "only the peg moves")
        #expect(PegMoment.squeeze.duration >= 0.18 && PegMoment.squeeze.duration <= 0.25)
        // Squeezed, the handles are narrower at the top than at rest, the jaws as wide.
        let pressed = try #require(frames.max { $0.pegPinch < $1.pegPinch })
        let restImage = try #require(GlyphInk.unclipped(Peg.pose(.idle), pad: 0))
        let pressedImage = try #require(GlyphInk.unclipped(pressed, pad: 0))
        func width(_ image: CGImage, atY y: CGFloat) -> Int {
            let row = Int(y * GlyphInk.scale)
            let a = GlyphInk.alpha(image)
            let xs = Int((Peg.peg.minX - 0.4) * GlyphInk.scale)...Int((Peg.peg.maxX + 0.4) * GlyphInk.scale)
            return xs.filter { a[row * image.width + $0] > 127 }.count
        }
        let handles = Peg.peg.minY + 0.9
        #expect(width(pressedImage, atY: handles) < width(restImage, atY: handles))
    }

    /// The squeeze reads on the menu bar's own pixels, 1x as well as 2x: in every squeezed
    /// frame the handles narrow and the jaw opens by whole pixels, not just a grey level of
    /// anti-aliasing.
    @Test(arguments: [CGFloat(1), 2])
    func squeezeMovesWholePixels(_ scale: CGFloat) throws {
        let play = Play(moment: .squeeze, from: .idle, to: .idle)
        let squeezed = Self.frames(play).filter { $0.pegPinch > 0.5 }
        #expect(squeezed.count >= 2)
        let rest = GlyphInk.alpha(try #require(GlyphInk.unclipped(Peg.pose(.idle), pad: 0, scale: scale)))
        for pose in squeezed {
            let image = GlyphInk.alpha(try #require(GlyphInk.unclipped(pose, pad: 0, scale: scale)))
            // Pixels that went from mostly ink to mostly clear, or back: whole-pixel changes.
            let flipped = zip(rest, image).filter { abs(Int($0) - Int($1)) >= 128 }.count
            #expect(flipped >= Int(2 * scale), "\(scale)x: \(flipped) pixels changed by half their coverage or more")
        }
        #expect(Peg.snapped(0.4, 1) == 1 && Peg.snapped(0.4, 2) == 0.5 && Peg.snapped(1.0, 2) == 1)
        #expect(Peg.snapped(0, 1) == 0)
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
            // Letting go drops the card out of the frame; a grip raises one from below it.
            // Both stay inside the sides while they do.
            if play.moment == .release && t < Peg.ReleaseBeat.drop.upperBound
                || play.moment == .grip && t < Peg.GripBeat.rise.upperBound {
                #expect(box.minX >= frame.minX - 1 && box.maxX <= frame.maxX + 1, "t \(t): ink outside the frame's sides")
                continue
            }
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
