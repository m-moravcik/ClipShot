#if DEBUG
import SwiftUI

// Task 12e proposals for ClipShot's own menu bar symbol. Debug only and separate from the
// production `StatusIcon`: once the owner picks one, the chosen concept is rebuilt as a
// custom SF Symbol and this file goes. Rendered by `SymbolConceptSheets`.

/// A frame of a concept: a resting state, or a moment of the copy animation.
enum ConceptFrame: Equatable, Sendable {
    case still(StatusIconState)
    /// Seconds into the copy animation, 0...`SymbolConcept.copyDuration`.
    case copy(Double)
}

/// The proposals. Each is a full state family drawn as vector paths in the 22 x 16 pt
/// status item frame, as a template (one ink, only opacity varies).
enum SymbolConcept: Int, CaseIterable, Identifiable, Sendable {
    case peg = 1, claw, stamp, pasty, pop, lasso

    var id: Int { rawValue }

    /// The whole copy animation.
    static let copyDuration = 1.5
    /// From here the copied pose crossfades back to idle.
    static let settleStart = 1.25

    var name: String {
        switch self {
        case .peg: "Peg"
        case .claw: "Claw"
        case .stamp: "Stamp"
        case .pasty: "Pasty"
        case .pop: "Pop"
        case .lasso: "Lasso"
        }
    }

    var slug: String { "\(rawValue)-\(name.lowercased())" }

    var pitch: String {
        switch self {
        case .peg: "Every shot gets pegged up on the line, ready to take down and paste."
        case .claw: "An arcade claw that never misses: it grabs the shot and holds it for you."
        case .stamp: "Copy as a rubber stamp: one press and the shot is inked onto the clipboard."
        case .pasty: "A little clipboard pal that gulps every shot and grins: ready to paste."
        case .pop: "Shots pop out like toast: instantly done, warm and ready."
        case .lasso: "Rope any piece of the screen and it comes home to your clipboard."
        }
    }

    var motion: String {
        switch self {
        case .peg: "Peg opens, old print drops, new print slides in along the line, peg snaps, print swings and develops with a check"
        case .claw: "Claw drops, closes on the shot, lifts with an overshoot, the shot swings"
        case .stamp: "Stamp winds up, slams with a squash and impact ticks, lifts off tilted over a fresh ink mark"
        case .pasty: "A shot drops into the clip, Pasty gulps (squash), hops with happy eyes and a grin, a sparkle pops"
        case .pop: "Toaster crouches, two slices pop up one after the other with pop marks and the lever, fall back with a bounce and toast"
        case .lasso: "Loop draws off, the shot appears, the loop draws on around it and cinches with a spring, a tug on the rope"
        }
    }

    /// What the final build would use.
    var mechanism: String {
        switch self {
        case .peg: "Keyframes (phase timer); with symbolEffect: .wiggle.rotational on the print layer + .replace to the copied symbol"
        case .claw: "Keyframes (phase timer); with symbolEffect: .bounce.down by layer + .replace.magic to the holding claw"
        case .stamp: "Keyframes (phase timer); with symbolEffect: .bounce.down (squash) + .replace.magic to the stamped symbol"
        case .pasty: "Keyframes (phase timer); with symbolEffect: .bounce.up whole symbol + .replace.magic face layers + .appear sparkle"
        case .pop: "Keyframes (phase timer); with symbolEffect: .bounce.up by layer on the slices + .replace.magic to the popped symbol"
        case .lasso: "Keyframes (phase timer); with symbolEffect: .drawOff / .drawOn on the loop + .replace.magic to the cinched symbol"
        }
    }

    /// Brings the drawing to the siblings' optical size: about 27 px of ink height at 2x,
    /// beside Eject Guard's 25 px wide drive.
    var opticalScale: CGFloat {
        switch self {
        case .peg, .pasty: 0.9
        case .claw: 0.9
        case .stamp: 0.93
        case .pop, .lasso: 1
        }
    }

    func draw(_ ink: Ink, _ frame: ConceptFrame) {
        switch self {
        case .peg: Peg.draw(ink, frame)
        case .claw: Claw.draw(ink, frame)
        case .stamp: Stamp.draw(ink, frame)
        case .pasty: Pasty.draw(ink, frame)
        case .pop: Pop.draw(ink, frame)
        case .lasso: Lasso.draw(ink, frame)
        }
    }
}

/// One concept in one frame, in the status item's 22 x 16 pt frame. Tinted by the
/// foreground style, like a template image.
struct ConceptGlyph: View {
    let concept: SymbolConcept
    let frame: ConceptFrame

    var body: some View {
        Canvas { context, _ in
            let ink = Ink(context).scaled(concept.opticalScale, concept.opticalScale, around: CGPoint(x: 11, y: 8))
            if case .copy(let t) = frame, t >= SymbolConcept.settleStart {
                let u = Motion.easeInOut(Motion.progress(t, SymbolConcept.settleStart, SymbolConcept.copyDuration))
                ink.layer(1 - u) { concept.draw($0, .still(.copied)) }
                ink.layer(u) { concept.draw($0, .still(.idle)) }
            } else {
                ink.layer { concept.draw($0, frame) }
            }
        }
        .frame(width: StatusIconArt.frame.width, height: StatusIconArt.frame.height)
    }
}

// MARK: - Drawing kit

/// A drawing context that paints with the foreground style.
struct Ink {
    var context: GraphicsContext
    static let line: CGFloat = 1.4

    init(_ context: GraphicsContext) {
        self.context = context
    }

    func stroke(_ path: Path, _ width: CGFloat = Ink.line, _ opacity: Double = 1, dash: [CGFloat] = []) {
        guard opacity > 0 else { return }
        var c = context
        c.opacity *= opacity
        c.stroke(path, with: .foreground,
                 style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }

    func fill(_ path: Path, _ opacity: Double = 1) {
        guard opacity > 0 else { return }
        var c = context
        c.opacity *= opacity
        c.fill(path, with: .foreground)
    }

    /// Cuts the path out of what is already drawn in this layer.
    func erase(_ path: Path) {
        var c = context
        c.blendMode = .destinationOut
        c.fill(path, with: .color(.black))
    }

    func eraseStroke(_ path: Path, _ width: CGFloat) {
        erase(path.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)))
    }

    func moved(_ dx: CGFloat, _ dy: CGFloat) -> Ink {
        var c = context
        c.translateBy(x: dx, y: dy)
        return Ink(c)
    }

    func rotated(_ degrees: Double, around p: CGPoint) -> Ink {
        var c = context
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: .degrees(degrees))
        c.translateBy(x: -p.x, y: -p.y)
        return Ink(c)
    }

    func scaled(_ sx: CGFloat, _ sy: CGFloat, around p: CGPoint) -> Ink {
        var c = context
        c.translateBy(x: p.x, y: p.y)
        c.scaleBy(x: sx, y: sy)
        c.translateBy(x: -p.x, y: -p.y)
        return Ink(c)
    }

    func clipped(to path: Path) -> Ink {
        var c = context
        c.clip(to: path)
        return Ink(c)
    }

    /// Draws into a layer of its own, composited at `opacity`, so erasing stays inside it.
    func layer(_ opacity: Double = 1, _ body: (Ink) -> Void) {
        guard opacity > 0 else { return }
        var c = context
        c.opacity *= opacity
        c.drawLayer { layer in body(Ink(layer)) }
    }
}

enum Shapes {
    static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r, style: .continuous)
    }

    static func line(_ points: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(points)
        return p
    }

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    /// An exclamation mark: a bar and a dot, centred on `cx`.
    static func bang(_ cx: CGFloat, top: CGFloat, bottom: CGFloat, width w: CGFloat) -> Path {
        var p = Path(roundedRect: CGRect(x: cx - w / 2, y: top, width: w, height: bottom - top - w * 1.75),
                     cornerRadius: w / 2)
        p.addEllipse(in: CGRect(x: cx - w / 2, y: bottom - w, width: w, height: w))
        return p
    }

    /// A four-pointed sparkle.
    static func sparkle(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        let i = r * 0.28
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + i, y: c.y - i))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + i, y: c.y + i))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - i, y: c.y + i))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - i, y: c.y - i))
        p.closeSubpath()
        return p
    }
}

/// Curves for explicit, timestamp-driven keyframes. Each one hits its end points exactly,
/// so a pose at the end of a segment is the next segment's start.
enum Motion {
    static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(1, max(0, (t - a) / (b - a)))
    }

    static func easeIn(_ u: Double) -> Double { u * u * u }
    static func easeOut(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
    static func easeInOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
    /// Overshoots by about 10 % before settling.
    static func backOut(_ u: Double, _ s: Double = 1.70158) -> Double {
        1 + (s + 1) * pow(u - 1, 3) + s * pow(u - 1, 2)
    }
    /// A spring from 0 to 1 with a visible overshoot, exactly 1 at u = 1.
    static func spring(_ u: Double, _ cycles: Double = 1.25) -> Double {
        1 - (1 - u) * exp(-3 * u) * cos(2 * .pi * cycles * u)
    }
    /// A decaying oscillation around 0, exactly 0 at both ends.
    static func wobble(_ u: Double, _ cycles: Double = 1.5) -> Double {
        (1 - u) * exp(-2.5 * u) * sin(2 * .pi * cycles * u)
    }
    /// 0 -> 1 -> 0.
    static func bump(_ u: Double) -> Double { sin(.pi * u) }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ u: Double) -> CGFloat { a + (b - a) * CGFloat(u) }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// MARK: - 1 Peg

/// A print pegged on a line, like photos drying in a darkroom.
private enum Peg {
    struct Print {
        var dx: CGFloat = 0, dy: CGFloat = 0
        var angle: Double = 0
        var fill: Double = 0
        var check: Double = 0
        var bang = false
        var dashed = false
        var opacity: Double = 1
    }

    struct Pose {
        var sag: Double = 0
        var pegLift: CGFloat = 0
        var pegSquash: CGFloat = 1
        var print = Print()
        var old: Print?
    }

    static let pivot = pt(11, 5.2)

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(print: Print(fill: 1, check: 1))
        case .still(.paused): return Pose(print: Print(dashed: true))
        case .still(.attention): return Pose(print: Print(angle: 24, bang: true))
        case .copy(let t):
            var p = Pose()
            p.pegLift = 1.4 * CGFloat(Motion.easeOut(Motion.progress(t, 0, 0.08)))
                * CGFloat(1 - Motion.easeIn(Motion.progress(t, 0.5, 0.58)))
            p.pegSquash = 1 - 0.18 * CGFloat(Motion.bump(Motion.progress(t, 0.56, 0.7)))
            let drop = Motion.progress(t, 0.04, 0.36)
            if drop < 1 {
                p.old = Print(dy: 13 * CGFloat(Motion.easeIn(drop)), angle: -14 * drop, opacity: 1 - drop * drop)
            }
            let slide = Motion.progress(t, 0.18, 0.56)
            let swing = Motion.progress(t, 0.56, 1.2)
            p.print = Print(
                dx: 15 * CGFloat(1 - Motion.easeOut(slide)),
                angle: -16 * (1 - Motion.easeOut(slide)) + 22 * Motion.wobble(swing, 1.6),
                fill: Motion.easeInOut(Motion.progress(t, 0.62, 0.86)),
                check: Motion.easeOut(Motion.progress(t, 0.8, 1.0)),
                opacity: t < 0.18 ? 0 : 1)
            p.sag = 1.4 * Motion.wobble(Motion.progress(t, 0.56, 1.1), 1.3)
            return p
        }
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        var line = Path()
        line.move(to: pt(1.2, 3.0))
        line.addQuadCurve(to: pt(20.8, 3.0), control: pt(11, 3.6 + 2 * CGFloat(p.sag)))
        ink.stroke(line, 1.2)
        if let old = p.old { drawPrint(ink, old) }
        drawPrint(ink, p.print)

        let peg = ink.moved(0, -p.pegLift).scaled(1, p.pegSquash, around: pt(11, 6.8))
        let body = Shapes.rr(9.4, 0.6, 3.2, 6.2, 1.3)
        peg.eraseStroke(body, 2.0)
        peg.fill(body)
        peg.erase(Shapes.ellipse(11, 3.0, 0.6, 0.6))
    }

    static func drawPrint(_ ink: Ink, _ print: Print) {
        let k = ink.moved(print.dx, print.dy).rotated(print.angle, around: pivot)
        k.layer(print.opacity) { k in
            let card = Shapes.rr(5.25, 5.2, 11.5, 9.4, 1.6)
            if print.dashed {
                k.stroke(card, 1.3, dash: [1.6, 1.5])
                return
            }
            k.stroke(card)
            if print.bang {
                k.fill(Shapes.bang(11, top: 7.4, bottom: 12.9, width: 1.7))
                return
            }
            k.fill(Shapes.ellipse(8.4, 8.3, 1.05, 1.05))
            k.fill(Shapes.line([pt(6.4, 13.4), pt(9.6, 9.8), pt(11.6, 11.8), pt(13.0, 10.6), pt(15.6, 13.4)]))
            if print.fill > 0 {
                let h = 9.4 * CGFloat(print.fill)
                k.clipped(to: card).fill(Path(CGRect(x: 5, y: 14.6 - h, width: 12, height: h + 0.2)))
            }
            if print.check > 0 {
                let check = Shapes.line([pt(7.9, 10.0), pt(10.1, 12.2), pt(14.1, 7.9)])
                k.eraseStroke(check.trimmedPath(from: 0, to: print.check), 1.6)
            }
        }
    }
}

// MARK: - 2 Claw

/// An arcade claw over a shot.
private enum Claw {
    struct Prize {
        var y: CGFloat = 12.6
        var angle: Double = 0
        var squash: CGFloat = 1
        var attached = false
    }

    struct Pose {
        var hy: CGFloat = 0
        var arms: Double = 14
        var prize: Prize? = Prize()
        var bang = false
    }

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(arms: -6, prize: Prize(y: 10.0, attached: true))
        case .still(.paused): return Pose(arms: -6, prize: nil)
        case .still(.attention): return Pose(prize: nil, bang: true)
        case .copy(let t):
            var p = Pose()
            let down = Motion.progress(t, 0, 0.3)
            let grab = Motion.progress(t, 0.3, 0.42)
            let lift = Motion.progress(t, 0.42, 0.85)
            p.hy = t < 0.42 ? 2.6 * CGFloat(Motion.easeInOut(down)) : 2.6 * CGFloat(1 - Motion.backOut(lift, 2.4))
            p.arms = t < 0.3 ? 14 + 8 * Motion.easeOut(down) : 22 - 28 * Motion.easeOut(grab)
            let squash = 1 - 0.14 * CGFloat(Motion.bump(Motion.progress(t, 0.33, 0.5)))
            if t < 0.36 {
                p.prize = Prize(squash: squash)
            } else {
                p.prize = Prize(y: p.hy + 10.0, angle: 14 * Motion.wobble(Motion.progress(t, 0.78, 1.2), 1.5),
                                squash: squash, attached: true)
            }
            return p
        }
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        ink.stroke(Shapes.line([pt(11, 0.3), pt(11, 2.7 + p.hy)]), 1.2)
        ink.fill(Shapes.rr(8.0, 2.4 + p.hy, 6.0, 2.6, 1.0))
        for side: CGFloat in [-1, 1] {
            let pivot = pt(11 + side * 2.1, 4.8 + p.hy)
            var arm = Path()
            arm.move(to: pivot)
            arm.addLine(to: pt(pivot.x + side * 3.0, pivot.y + 3.4))
            arm.addQuadCurve(to: pt(pivot.x + side * 1.4, pivot.y + 7.6), control: pt(pivot.x + side * 3.6, pivot.y + 6.4))
            ink.rotated(-Double(side) * p.arms, around: pivot).stroke(arm)
        }
        if let prize = p.prize {
            let k = ink.rotated(prize.angle, around: pt(11, p.hy + 5.2))
                .scaled(prize.squash, 2 - prize.squash, around: pt(11, prize.y + 1.9))
            let tile = Shapes.rr(8.7, prize.y - 1.9, 4.6, 3.8, 0.9)
            k.eraseStroke(tile, 1.4)
            k.fill(tile)
        }
        if p.bang {
            ink.fill(Shapes.bang(11, top: 7.6, bottom: 14.6, width: 1.8))
        }
    }
}

// MARK: - 3 Stamp

/// A rubber stamp over a sheet of paper.
private enum Stamp {
    struct Pose {
        var dx: CGFloat = 0, dy: CGFloat = 0
        var sx: CGFloat = 1, sy: CGFloat = 1
        var angle: Double = 0
        var mark: Double = 0
        var ticks: Double = 0
        var lying = false
        var bang = false
    }

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(angle: -10, mark: 1)
        case .still(.paused): return Pose(lying: true)
        case .still(.attention): return Pose(dx: -3.4, bang: true)
        case .copy(let t):
            var p = Pose()
            let windUp = Motion.progress(t, 0, 0.2)
            let slam = Motion.progress(t, 0.2, 0.3)
            let squash = Motion.progress(t, 0.3, 0.5)
            let lift = Motion.progress(t, 0.5, 0.9)
            if t < 0.2 {
                p.dy = -1.4 * CGFloat(Motion.easeOut(windUp))
                p.sy = 1 + 0.06 * CGFloat(windUp)
                p.sx = 1 - 0.04 * CGFloat(windUp)
            } else if t < 0.5 {
                p.dy = -1.4 + 4.6 * CGFloat(Motion.easeIn(slam))
                let b = CGFloat(Motion.bump(squash))
                p.sy = t < 0.3 ? 1.06 - 0.06 * CGFloat(slam) : 1 - 0.2 * b
                p.sx = t < 0.3 ? 0.96 + 0.04 * CGFloat(slam) : 1 + 0.12 * b
            } else {
                p.dy = 3.2 * CGFloat(1 - Motion.backOut(lift, 2.0))
                p.angle = -10 * Motion.easeOut(lift)
            }
            p.ticks = Motion.bump(Motion.progress(t, 0.3, 0.62))
            p.mark = t >= 0.5 ? 1 : 0
            return p
        }
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        ink.stroke(Shapes.line([pt(3.0, 14.4), pt(19.0, 14.4)]), 1.2)
        ink.fill(Shapes.rr(6.4, 11.4, 9.2, 2.4, 0.6), p.mark)
        for side: CGFloat in [-1, 1] {
            ink.stroke(Shapes.line([pt(11 + side * 7.0, 12.6), pt(11 + side * 8.6, 11.2)]), 1.1, p.ticks)
            ink.stroke(Shapes.line([pt(11 + side * 7.4, 14.0), pt(11 + side * 9.4, 13.6)]), 1.1, p.ticks)
        }
        let k: Ink
        if p.lying {
            k = ink.moved(0.4, 2.6).rotated(-90, around: pt(11, 5.6))
        } else {
            k = ink.moved(p.dx, p.dy).rotated(p.angle, around: pt(11, 10.8)).scaled(p.sx, p.sy, around: pt(11, 10.8))
        }
        k.fill(Shapes.ellipse(11, 2.5, 2.3, 1.9))
        k.fill(Shapes.rr(10.0, 3.8, 2.0, 2.6, 0.5))
        var block = Path()
        block.addLines([pt(7.4, 6.2), pt(14.6, 6.2), pt(16.0, 8.6), pt(6.0, 8.6)])
        block.closeSubpath()
        k.stroke(block)
        k.fill(Shapes.rr(5.2, 9.3, 11.6, 1.5, 0.5))
        if p.bang {
            ink.fill(Shapes.bang(18.6, top: 1.2, bottom: 12.8, width: 1.9))
        }
    }
}

// MARK: - 4 Pasty

/// A clipboard with a face.
private enum Pasty {
    enum Eyes { case dots, happy, sleep, wide }
    enum Mouth { case smile, grin, none, oh }

    struct Pose {
        var dy: CGFloat = 0
        var sx: CGFloat = 1, sy: CGFloat = 1
        var eyes = Eyes.dots
        var mouth = Mouth.smile
        var sparkle: Double = 0
        var z = false
        var bang = false
        var shotY: CGFloat?
    }

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(eyes: .happy, mouth: .grin, sparkle: 1)
        case .still(.paused): return Pose(eyes: .sleep, mouth: .none, z: true)
        case .still(.attention): return Pose(eyes: .wide, mouth: .oh, bang: true)
        case .copy(let t):
            var p = Pose()
            if t < 0.22 {
                p.shotY = -4 + 6.4 * CGFloat(Motion.easeIn(Motion.progress(t, 0, 0.22)))
            }
            let gulp = CGFloat(Motion.bump(Motion.progress(t, 0.22, 0.36)))
            let hop = Motion.progress(t, 0.36, 0.8)
            let land = CGFloat(Motion.bump(Motion.progress(t, 0.7, 0.86)))
            p.sy = 1 - 0.14 * gulp + 0.07 * CGFloat(Motion.bump(min(1, hop * 1.6))) - 0.06 * land
            p.sx = 1 + 0.08 * gulp - 0.03 * CGFloat(Motion.bump(min(1, hop * 1.6))) + 0.04 * land
            p.dy = -0.9 * CGFloat(Motion.bump(min(1, hop * 1.4)))
            if t >= 0.22 { p.eyes = .wide }
            if t >= 0.4 {
                p.eyes = .happy
                p.mouth = .grin
            }
            p.sparkle = Motion.backOut(Motion.progress(t, 0.5, 0.85), 2.2)
            return p
        }
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        let k = ink.moved(0, p.dy).scaled(p.sx, p.sy, around: pt(11, 15.0))
        k.stroke(Shapes.rr(5.6, 2.6, 10.8, 12.4, 2.4))
        if let y = p.shotY {
            k.fill(Shapes.rr(8.9, y, 4.2, 3.2, 0.8))
        }
        let clip = Shapes.rr(8.4, 0.9, 5.2, 3.0, 1.1)
        k.eraseStroke(clip, 1.6)
        k.fill(clip)

        for x: CGFloat in [9.0, 13.0] {
            switch p.eyes {
            case .dots: k.fill(Shapes.ellipse(x, 8.4, 1.15, 1.15))
            case .wide: k.fill(Shapes.ellipse(x, 8.2, 1.55, 1.55))
            case .happy: k.stroke(Shapes.line([pt(x - 1.15, 9.0), pt(x, 7.8), pt(x + 1.15, 9.0)]), 1.2)
            case .sleep:
                var lid = Path()
                lid.move(to: pt(x - 1.15, 8.4))
                lid.addQuadCurve(to: pt(x + 1.15, 8.4), control: pt(x, 9.6))
                k.stroke(lid, 1.15)
            }
        }
        switch p.mouth {
        case .smile:
            var m = Path()
            m.move(to: pt(9.7, 11.2))
            m.addQuadCurve(to: pt(12.3, 11.2), control: pt(11, 12.6))
            k.stroke(m, 1.1)
        case .grin:
            var m = Path()
            m.move(to: pt(9.2, 10.8))
            m.addLine(to: pt(12.8, 10.8))
            m.addQuadCurve(to: pt(9.2, 10.8), control: pt(11, 14.2))
            m.closeSubpath()
            k.fill(m)
        case .oh: k.stroke(Shapes.ellipse(11, 11.9, 0.9, 1.0), 1.1)
        case .none: break
        }
        if p.sparkle > 0 {
            let s = CGFloat(p.sparkle)
            ink.rotated(45 * (1 - p.sparkle), around: pt(19.3, 3.4)).fill(Shapes.sparkle(pt(19.3, 3.4), 2.7 * s))
        }
        if p.z {
            ink.stroke(Shapes.line([pt(17.6, 1.2), pt(20.6, 1.2), pt(17.6, 4.6), pt(20.6, 4.6)]), 1.15)
        }
        if p.bang {
            ink.fill(Shapes.bang(19.4, top: 1.6, bottom: 11.8, width: 1.8))
        }
    }
}

// MARK: - 5 Pop

/// A toaster with two slices: the shots.
private enum Pop {
    struct Pose {
        var tops: [CGFloat]? = [3.4, 3.4]
        var toast: Double = 0
        var lever: CGFloat = 12.6
        var sy: CGFloat = 1
        var pops: Double = 0
        var bang = false
        var dy: CGFloat = 0
    }

    static let slots: [CGFloat] = [5.4, 11.8]

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(tops: [0.6, 0.6], toast: 1, lever: 8.8)
        case .still(.paused): return Pose(tops: nil, dy: -2.2)
        case .still(.attention): return Pose(bang: true)
        case .copy(let t):
            var p = Pose()
            p.tops = [top(t), top(t - 0.07)]
            let crouch = Motion.progress(t, 0, 0.16)
            let fall = Motion.progress(t, 0.4, 0.8)
            if t < 0.16 {
                p.sy = 1 - 0.08 * CGFloat(crouch)
            } else if t < 0.4 {
                p.sy = 0.92 + 0.08 * CGFloat(Motion.easeOut(Motion.progress(t, 0.16, 0.4)))
            } else {
                p.sy = 1 + 0.06 * CGFloat(Motion.wobble(fall, 1.5))
            }
            p.lever = t < 0.16 ? 12.6 : Motion.lerp(12.6, 8.8, Motion.easeOut(Motion.progress(t, 0.16, 0.24)))
            p.toast = Motion.easeInOut(Motion.progress(t, 0.4, 0.85))
            p.pops = Motion.bump(Motion.progress(t, 0.18, 0.55))
            return p
        }
    }

    /// One slice's top over time: crouch, shoot up past its rest, fall back with a spring.
    static func top(_ t: Double) -> CGFloat {
        if t < 0.16 { return 3.4 + 1.2 * CGFloat(Motion.easeOut(Motion.progress(t, 0, 0.16))) }
        if t < 0.4 { return 4.6 - 5.8 * CGFloat(Motion.easeOut(Motion.progress(t, 0.16, 0.4))) }
        return Motion.lerp(-1.2, 0.6, Motion.spring(Motion.progress(t, 0.4, 0.85), 1.25))
    }

    static func slice(_ x: CGFloat, _ top: CGFloat, closed: Bool) -> Path {
        var p = Path()
        p.move(to: pt(x + 0.6, top + 10))
        p.addLine(to: pt(x + 0.6, top + 2.2))
        p.addCurve(to: pt(x + 2.4, top), control1: pt(x - 0.7, top + 1.1), control2: pt(x + 0.6, top))
        p.addCurve(to: pt(x + 4.2, top + 2.2), control1: pt(x + 4.2, top), control2: pt(x + 5.5, top + 1.1))
        p.addLine(to: pt(x + 4.2, top + 10))
        if closed { p.closeSubpath() }
        return p
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        let k = ink.moved(0, p.dy)
        let bodyInk = k.scaled(1, p.sy, around: pt(11, 15.0))
        let body = Shapes.rr(3.0, 7.6, 16.0, 7.4, 2.2)
        if let tops = p.tops {
            for (x, top) in zip(slots, tops) {
                k.stroke(slice(x, top, closed: false), 1.3)
                if p.toast > 0 {
                    let h = (16 - top) * CGFloat(p.toast)
                    k.clipped(to: slice(x, top, closed: true)).fill(Path(CGRect(x: x - 1, y: 16 - h, width: 7, height: h)))
                }
            }
        }
        bodyInk.erase(body)
        if p.bang {
            bodyInk.fill(body)
            bodyInk.erase(Shapes.bang(11, top: 9.0, bottom: 13.8, width: 1.6))
        } else {
            bodyInk.stroke(body)
            if p.tops == nil {
                for x in slots { bodyInk.erase(Path(CGRect(x: x + 0.4, y: 6.6, width: 4.0, height: 2.0))) }
            }
        }
        k.fill(Shapes.rr(19.0, p.lever, 2.0, 1.4, 0.6))
        for side: CGFloat in [-1, 1] {
            k.stroke(Shapes.line([pt(11 + side * 7.4, 5.6), pt(11 + side * 8.5, 4.0)]), 1.1, p.pops)
        }
    }
}

// MARK: - 6 Lasso

/// A lasso: rope trailing into a loop with a knot.
private enum Lasso {
    struct Pose {
        var cx: CGFloat = 14.2, cy: CGFloat = 6.9
        var rx: CGFloat = 6.2, ry: CGFloat = 5.2
        var trim: Double = 1
        var tile: Double = 0
        var tileSX: CGFloat = 1
        var dx: CGFloat = 0
        var coil = false
        var bang = false
    }

    static let tilt = -10.0
    static let start = 170.0
    static let tileCenter = pt(14.6, 7.6)

    static func pose(_ frame: ConceptFrame) -> Pose {
        switch frame {
        case .still(.idle): return Pose()
        case .still(.copied): return Pose(cx: 14.6, cy: 7.6, rx: 3.8, ry: 3.0, tile: 1)
        case .still(.paused): return Pose(coil: true)
        case .still(.attention): return Pose(bang: true)
        case .copy(let t):
            var p = Pose()
            p.trim = t < 0.14 ? 1 - Motion.easeIn(Motion.progress(t, 0, 0.14)) : Motion.easeOut(Motion.progress(t, 0.16, 0.5))
            p.tile = Motion.backOut(Motion.progress(t, 0.1, 0.3), 2.2)
            let cinch = Motion.spring(Motion.progress(t, 0.5, 0.85), 1.25)
            p.cx = Motion.lerp(14.2, 14.6, cinch)
            p.cy = Motion.lerp(6.9, 7.6, cinch)
            p.rx = Motion.lerp(6.2, 3.8, cinch)
            p.ry = Motion.lerp(5.2, 3.0, cinch)
            p.tileSX = 1 - 0.2 * CGFloat(Motion.bump(Motion.progress(t, 0.55, 0.75)))
            p.dx = -1.4 * CGFloat(Motion.wobble(Motion.progress(t, 0.82, 1.18), 1.2))
            return p
        }
    }

    static func point(_ p: Pose, _ degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180, r = tilt * .pi / 180
        let x = p.rx * CGFloat(cos(a)), y = p.ry * CGFloat(sin(a))
        return pt(p.cx + x * CGFloat(cos(r)) - y * CGFloat(sin(r)), p.cy + x * CGFloat(sin(r)) + y * CGFloat(cos(r)))
    }

    static func loop(_ p: Pose) -> Path {
        var path = Path()
        let steps = 72
        path.move(to: point(p, start))
        for i in 1...steps { path.addLine(to: point(p, start + 360 * Double(i) / Double(steps))) }
        return path
    }

    static func draw(_ ink: Ink, _ frame: ConceptFrame) {
        let p = pose(frame)
        let k = ink.moved(p.dx, 0)
        if p.coil {
            k.stroke(Shapes.ellipse(12.6, 8.0, 7.4, 5.4))
            k.stroke(Shapes.ellipse(12.6, 8.0, 4.0, 2.4))
            var end = Path()
            end.move(to: pt(6.6, 11.6))
            end.addCurve(to: pt(1.4, 14.8), control1: pt(4.6, 13.8), control2: pt(3.6, 12.2))
            k.eraseStroke(end, 2.6)
            k.stroke(end)
            return
        }
        if p.tile > 0 {
            let s = CGFloat(p.tile)
            let c = tileCenter
            k.scaled(s * p.tileSX, s * (2 - p.tileSX), around: c).fill(Shapes.rr(c.x - 1.8, c.y - 1.4, 3.6, 2.8, 0.7))
        }
        if p.trim > 0 {
            k.stroke(loop(p).trimmedPath(from: 0, to: p.trim))
        }
        let knot = point(p, start)
        var rope = Path()
        rope.move(to: knot)
        rope.addCurve(to: pt(1.2, 12.4), control1: pt(knot.x - 2.8, knot.y - 3.8), control2: pt(3.2, 16.2))
        k.stroke(rope)
        k.fill(Shapes.ellipse(knot.x, knot.y, 1.35, 1.35))
        if p.bang {
            k.fill(Shapes.bang(14.2, top: 3.4, bottom: 10.6, width: 1.7))
        }
    }
}
#endif
