import AppKit

/// ClipShot's menu bar character: a picture pegged on a line, like a print drying in a
/// darkroom. Every screenshot gets pegged up, ready to take down and paste.
///
/// Drawn with Core Graphics as one template image per pose, in the status item's
/// 22 x 16 pt frame, y down. One ink, only coverage and opacity vary, so the menu bar tints
/// it like any template image (light, dark, highlighted, tinted wallpaper).
///
/// A `MenuBarExtra` label is handed to the status item as a static image, so symbol effects
/// never run there (docs/spike-2026-10-19.md, F-menubar-anim). The copy animation is a
/// keyframe timeline instead: `pose(at:)` maps a time to a pose, and the phase timer of
/// `CopiedFlash` draws one pose per frame while it plays.
enum Peg {
    /// The status item's frame. Everything resting stays inside it; the copy animation slides
    /// cards in and out across its edges, which the status item clips.
    static let canvas = CGSize(width: 22, height: 16)

    // MARK: Geometry (points, y down)

    /// The card's outline weight, matched to the siblings' regular-weight symbols.
    static let stroke: CGFloat = 1.1
    /// The line is a string: a touch lighter, and on whole pixels at 1x.
    static let lineWeight: CGFloat = 1.0
    static let lineY: CGFloat = 3.5
    /// Short enough that the whole glyph is no wider than Eject Guard's drive.
    static let lineEnds: ClosedRange<CGFloat> = 3.0...19.0
    /// The card, hanging from the peg.
    static let card = CGRect(x: 5.55, y: 5.0, width: 10.9, height: 9.15)
    static let cardRadius: CGFloat = 1.6
    /// The clothes peg, centred on the line.
    static let peg = CGRect(x: 9.6, y: 1.5, width: 2.8, height: 5.35)
    static let pegRadius: CGFloat = 1.25
    /// The gap cut around the peg, so it reads in front of the line and the card.
    static let pegGap: CGFloat = 1.6
    static let spring = CGPoint(x: 11, y: 3.5)
    /// The card swings around the peg's bite.
    static let pivot = CGPoint(x: 11, y: 5.0)

    // MARK: Poses

    struct Card: Hashable, Sendable {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        /// Degrees, clockwise.
        var angle: Double = 0
        /// How far the solid "copied" fill has risen from the bottom, 0...1.
        var fill: Double = 0
        /// How much of the knocked-out check is drawn, 0...1.
        var check: Double = 0
        var dashed = false
        var bang = false
        var opacity: Double = 1
    }

    struct Pose: Hashable, Sendable {
        /// The line's dip under the peg, in points (negative springs up).
        var sag: CGFloat = 0
        var pegLift: CGFloat = 0
        var pegSquash: CGFloat = 1
        var card = Card()
        /// The previous shot falling away.
        var old: Card?
    }

    static func pose(_ state: StatusIconState) -> Pose {
        switch state {
        case .idle: Pose()
        case .copied: Pose(card: Card(fill: 1, check: 1))
        case .paused: Pose(card: Card(dashed: true))
        case .attention: Pose(card: Card(angle: 17, bang: true))
        }
    }

    /// The pose the menu bar shows: a resting state, or a frame of the copy animation.
    /// Reduce Motion holds the copied pose with no movement.
    static func pose(state: StatusIconState, phase: Int, reduceMotion: Bool) -> Pose {
        guard state == .copied, phase > 0, !reduceMotion else { return pose(state) }
        return pose(at: CopiedFlash.time(phase: phase))
    }

    /// Beats of the copy animation, in seconds. It confirms the copy with some character:
    /// the peg opens, the last shot drops, the new one slides in along the line, gets pegged
    /// with a squash, swings and bobs on the line, develops from the bottom and shows a
    /// check; after a beat it fades back into a picture, at rest by `CopiedFlash.duration`.
    enum Beat {
        static let pegOpen = 0.0...0.08
        static let oldDrop = 0.02...0.22
        static let slideIn = 0.12...0.4
        static let pegShut = 0.38...0.44
        static let pegBite = 0.42...0.54
        static let swing = 0.42...1.0
        static let bob = 0.42...0.95
        static let develop = 0.56...0.78
        static let checkOn = 0.74...0.92
        static let checkOff = 1.2...1.28
        static let drain = 1.24...1.44
    }

    static func pose(at t: TimeInterval) -> Pose {
        var p = Pose()
        p.pegLift = 1.3 * Curve.easeOut(Curve.progress(t, Beat.pegOpen))
            * (1 - Curve.easeIn(Curve.progress(t, Beat.pegShut)))
        p.pegSquash = 1 - 0.2 * Curve.bump(Curve.progress(t, Beat.pegBite))

        let drop = Curve.progress(t, Beat.oldDrop)
        if drop < 1 {
            p.old = Card(dy: 13 * Curve.easeIn(drop), angle: -12 * drop, opacity: 1 - drop * drop)
        }

        let slide = Curve.easeOut(Curve.progress(t, Beat.slideIn))
        p.sag = 1.5 * Curve.wobble(Curve.progress(t, Beat.bob), cycles: 1.3)
        p.card = Card(
            dx: 13 * (1 - slide),
            dy: 0.9 * p.sag,
            angle: -18 * (1 - slide) + 20 * Curve.wobble(Curve.progress(t, Beat.swing), cycles: 1.6),
            fill: Curve.easeInOut(Curve.progress(t, Beat.develop))
                - Curve.easeInOut(Curve.progress(t, Beat.drain)),
            check: Curve.easeOut(Curve.progress(t, Beat.checkOn))
                - Curve.easeIn(Curve.progress(t, Beat.checkOff)),
            opacity: t < Beat.slideIn.lowerBound ? 0 : 1)
        return p
    }

    // MARK: Drawing

    /// Draws `pose` into `context`, whose user space is the 22 x 16 pt canvas with y down.
    /// Everything goes into one transparency layer, so the gaps it cuts never reach what is
    /// behind the image.
    static func draw(_ pose: Pose, in context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let line = CGMutablePath()
        line.move(to: CGPoint(x: lineEnds.lowerBound, y: lineY))
        line.addQuadCurve(to: CGPoint(x: lineEnds.upperBound, y: lineY),
                          control: CGPoint(x: 11, y: lineY + 0.5 + 2 * pose.sag))
        stroke(line, lineWeight, in: context)

        if let old = pose.old { drawCard(old, in: context) }
        drawCard(pose.card, in: context)

        // The peg, in front: a gap around it, the body, the spring hole.
        var pegTransform = CGAffineTransform(translationX: 0, y: -pose.pegLift)
            .concatenating(scale(1, pose.pegSquash, around: CGPoint(x: 11, y: peg.maxY - pose.pegLift)))
        let body = CGPath(roundedRect: peg, cornerWidth: pegRadius, cornerHeight: pegRadius,
                          transform: &pegTransform)
        erase(body.copy(strokingWithWidth: pegGap, lineCap: .round, lineJoin: .round, miterLimit: 10), in: context)
        context.addPath(body)
        context.fillPath()
        let hole = CGPath(ellipseIn: CGRect(x: spring.x - 0.55, y: spring.y - 0.55, width: 1.1, height: 1.1),
                          transform: &pegTransform)
        erase(hole, in: context)

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func drawCard(_ card: Card, in context: CGContext) {
        guard card.opacity > 0 else { return }
        context.saveGState()
        context.setAlpha(card.opacity)
        context.translateBy(x: card.dx, y: card.dy)
        context.translateBy(x: pivot.x, y: pivot.y)
        context.rotate(by: card.angle * .pi / 180)
        context.translateBy(x: -pivot.x, y: -pivot.y)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer {
            context.endTransparencyLayer()
            context.restoreGState()
        }

        let outline = CGPath(roundedRect: Self.card, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        if card.dashed {
            stroke(outline.copy(dashingWithPhase: 0, lengths: [1.6, 1.5]), stroke, in: context)
            return
        }
        stroke(outline, stroke, in: context)
        if card.bang {
            context.addPath(bang(centerX: 11, top: 7.2, bottom: 13.0, width: 1.6))
            context.fillPath()
            return
        }
        // The picture: a sun and one bold peak standing on the card's edge. Finer detail
        // (a second ridge, a stroked outline) turns to mush at 1x.
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.addEllipse(in: CGRect(x: 7.3, y: 7.3, width: 2.2, height: 2.2))
        let peak = CGMutablePath()
        peak.move(to: CGPoint(x: 6.2, y: 14.2))
        peak.addLine(to: CGPoint(x: 11.6, y: 8.9))
        peak.addLine(to: CGPoint(x: 16.4, y: 13.2))
        peak.addLine(to: CGPoint(x: 16.4, y: 14.2))
        peak.closeSubpath()
        context.addPath(peak)
        context.fillPath()
        context.restoreGState()

        if card.fill > 0 {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let h = (Self.card.height + 1) * card.fill
            context.fill(CGRect(x: Self.card.minX - 1, y: Self.card.maxY + 0.5 - h, width: Self.card.width + 2, height: h))
            context.restoreGState()
        }
        if card.check > 0 {
            let check = CGMutablePath()
            check.move(to: CGPoint(x: 8.0, y: 10.2))
            check.addLine(to: CGPoint(x: 10.2, y: 12.3))
            check.addLine(to: CGPoint(x: 14.0, y: 8.2))
            erase(trimmed(check, to: card.check).copy(strokingWithWidth: 1.6, lineCap: .round,
                                                       lineJoin: .round, miterLimit: 10), in: context)
        }
    }

    private static func stroke(_ path: CGPath, _ width: CGFloat, in context: CGContext) {
        context.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        context.fillPath()
    }

    private static func erase(_ path: CGPath, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// An exclamation mark: a bar and a dot, centred on `centerX`.
    private static func bang(centerX: CGFloat, top: CGFloat, bottom: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: centerX - width / 2, y: top, width: width, height: bottom - top - width * 1.75),
                            cornerWidth: width / 2, cornerHeight: width / 2)
        path.addEllipse(in: CGRect(x: centerX - width / 2, y: bottom - width, width: width, height: width))
        return path
    }

    /// The first `fraction` of a polyline, by length.
    private static func trimmed(_ path: CGPath, to fraction: Double) -> CGPath {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            if e.type == .moveToPoint || e.type == .addLineToPoint { points.append(e.points[0]) }
        }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = lengths.reduce(0, +) * CGFloat(min(1, max(0, fraction)))
        let result = CGMutablePath()
        guard let first = points.first else { return result }
        result.move(to: first)
        for (i, length) in lengths.enumerated() {
            let a = points[i], b = points[i + 1]
            if left >= length {
                result.addLine(to: b)
                left -= length
            } else {
                let u = length > 0 ? left / length : 0
                result.addLine(to: CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
                break
            }
        }
        return result
    }

    private static func scale(_ sx: CGFloat, _ sy: CGFloat, around p: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -p.x, y: -p.y)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: p.x, y: p.y))
    }

    // MARK: Images

    @MainActor private static var images: [Pose: NSImage] = [:]

    /// The template image of `pose`, drawn at whatever scale it is displayed (crisp at 1x
    /// and 2x). Cached: the animation has a fixed set of frames.
    @MainActor
    static func image(_ pose: Pose) -> NSImage {
        if let image = images[pose] { return image }
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(pose, in: context)
            return true
        }
        image.isTemplate = true
        images[pose] = image
        return image
    }

    // MARK: Curves

    /// Timestamp-driven curves. Each one hits its end points exactly, so a pose at the end
    /// of a beat is the next beat's start, and the last frame is exactly at rest.
    enum Curve {
        static func progress(_ t: Double, _ beat: ClosedRange<Double>) -> Double {
            min(1, max(0, (t - beat.lowerBound) / (beat.upperBound - beat.lowerBound)))
        }

        static func easeIn(_ u: Double) -> Double { u * u * u }
        static func easeOut(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
        static func easeInOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
        /// A decaying oscillation around 0, exactly 0 at both ends.
        static func wobble(_ u: Double, cycles: Double) -> Double {
            (1 - u) * exp(-2.5 * u) * sin(2 * .pi * cycles * u)
        }
        /// 0 -> 1 -> 0.
        static func bump(_ u: Double) -> Double { sin(.pi * u) }
    }
}
