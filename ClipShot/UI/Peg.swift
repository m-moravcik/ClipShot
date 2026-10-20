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
/// `PegFlash` draws one pose per frame while it plays. The same mechanism plays Peg's other
/// moments (`PegMoment`): swinging into the attention pose, pausing and resuming.
enum Peg {
    /// The status item's frame. Everything resting stays inside it; the copy animation slides
    /// cards in and out across its edges, which the status item clips.
    static let canvas = CGSize(width: 22, height: 16)

    // MARK: Geometry (points, y down)

    /// The card's outline weight, matched to the siblings' regular-weight symbols.
    static let stroke: CGFloat = 1.1
    /// The card carries the glyph's weight, so it is as large as the siblings' main shapes
    /// (Eject Guard's drive, VibeRes's front window): nearly the whole width, and most of the
    /// height, with the peg biting deep into its top edge.
    static let card = CGRect(x: 3.2, y: 3.9, width: 15.6, height: 10.55)
    static let cardRadius: CGFloat = 1.8
    /// The line is a short accent above the card, lighter than the card's outline: on whole
    /// pixels at 1x, and drawn at `lineOpacity`.
    static let lineWeight: CGFloat = 1.0
    static let lineY: CGFloat = 1.5
    static let lineEnds: ClosedRange<CGFloat> = 5.5...16.5
    static let lineOpacity: CGFloat = 0.6
    /// The clothes peg, centred on the card, from above the line deep over the card's edge.
    static let peg = CGRect(x: 9.5, y: 0.55, width: 3.0, height: 6.45)
    static let pegRadius: CGFloat = 1.3
    /// The gap cut around the peg, so it reads in front of the line and the card.
    static let pegGap: CGFloat = 1.6
    static let spring = CGPoint(x: 11, y: 2.6)
    /// The card swings around the peg's bite.
    static let pivot = CGPoint(x: 11, y: card.minY)

    /// A point of the card's artwork, laid out on the card as a fraction of its width and
    /// height (0...1 from its top leading corner).
    static func onCard(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: card.minX + u * card.width, y: card.minY + v * card.height)
    }

    /// Sizes inside the card (sun, check, exclamation mark) follow its height, so round
    /// things stay round: 1 at the 9.15 pt card they were first drawn for.
    static let artScale = card.height / 9.15

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
        /// How much of the outline is broken into dashes, from the bottom up: 0 solid, 1 the
        /// paused card's dashed outline.
        var dash: Double = 0
        /// The picture's opacity (the sun and the peak), 0...1.
        var picture: Double = 1
        /// The "!" mark's opacity, 0...1.
        var bang: Double = 0
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

    /// The attention card hangs askew from the peg, lifted a little so it stays in the frame.
    static let attentionAngle: Double = 7
    static let attentionLift: CGFloat = -0.8

    static func pose(_ state: StatusIconState) -> Pose {
        switch state {
        case .idle: Pose()
        case .copied: Pose(card: Card(fill: 1, check: 1))
        case .paused: Pose(card: Card(dash: 1, picture: 0))
        case .attention: Pose(card: Card(dy: attentionLift, angle: attentionAngle, picture: 0, bang: 1))
        }
    }

    /// The pose the menu bar shows: a resting state, or a frame of the copy animation that
    /// starts and ends on the picture. Reduce Motion holds the copied pose with no movement.
    static func pose(state: StatusIconState, phase: Int, reduceMotion: Bool) -> Pose {
        guard state == .copied, phase > 0, !reduceMotion else { return pose(state) }
        return pose(at: PegFlash.time(phase: phase))
    }

    /// The pose the menu bar shows while `moment` plays (phase > 0), or at `rest`.
    ///
    /// `rest` is the state the icon settles in: the copy animation ends on it (a copy while
    /// paused ends on the dashed card, one while something needs attention on the "!" card),
    /// and the other moments always end on theirs. `from` is the state the icon rested in
    /// when the moment started. Reduce Motion: the copy is a held copied pose; every other
    /// moment is the resting pose at once.
    static func pose(
        rest: StatusIconState, moment: PegMoment?, phase: Int, from: StatusIconState, reduceMotion: Bool
    ) -> Pose {
        guard let moment, phase > 0 else { return pose(rest) }
        let t = PegFlash.time(phase: phase)
        switch moment {
        case .copied: return reduceMotion ? pose(.copied) : pose(at: t, from: from, to: rest)
        case _ where reduceMotion: return pose(rest)
        case .attention: return attentionPose(at: t, from: from)
        case .pause: return pausePose(at: t)
        case .resume: return resumePose(at: t)
        }
    }

    /// Beats of the copy animation, in seconds. It confirms the copy with some character:
    /// the peg opens, the last shot drops, the new one slides in along the line, gets pegged
    /// with a clamp that lands with a little bounce, swings and bobs on the line, develops
    /// from the bottom and shows a check, which holds; then it fades back into a picture, at
    /// rest by `PegMoment.copied.duration`. The pinning (slide, clamp, swing) is slow enough to
    /// follow in the corner of the eye; the old shot's drop stays quick.
    enum Beat {
        static let pegOpen = 0.0...0.14
        static let oldDrop = 0.04...0.34
        static let slideIn = 0.2...0.76
        static let pegShut = 0.72...0.86
        static let clampBounce = 0.84...1.2
        static let swing = 0.84...1.9
        static let bob = 0.84...1.8
        static let develop = 1.0...1.3
        static let checkOn = 1.26...1.5
        static let checkOff = 2.0...2.1
        static let drain = 2.04...2.3
    }

    /// A frame of the copy animation from the picture back to the picture.
    static func pose(at t: TimeInterval) -> Pose {
        pose(at: t, from: .idle, to: .idle)
    }

    /// A frame of the copy animation: the card that drops is the one `from` rested on, and
    /// the new card turns into `to`'s card as the copied fill drains.
    static func pose(at t: TimeInterval, from: StatusIconState, to: StatusIconState) -> Pose {
        var p = Pose()
        // Open (its jaw lifts off the card), shut, then a little bounce as the clamp lands:
        // it bites past its rest, squashing, and springs back.
        let bounce = Curve.wobble(Curve.progress(t, Beat.clampBounce), cycles: 1.5)
        p.pegLift = 1.3 * Curve.easeOut(Curve.progress(t, Beat.pegOpen))
            * (1 - Curve.easeIn(Curve.progress(t, Beat.pegShut)))
            - 0.9 * bounce
        p.pegSquash = 1 - 0.3 * bounce

        let drop = Curve.progress(t, Beat.oldDrop)
        if drop < 1 {
            var old = restingCard(from)
            old.dy += 13 * Curve.easeIn(drop)
            old.angle += -12 * drop
            old.opacity = 1 - drop * drop
            p.old = old
        }

        let slide = Curve.easeOut(Curve.progress(t, Beat.slideIn))
        p.sag = 1.5 * Curve.wobble(Curve.progress(t, Beat.bob), cycles: 1.3)
        let angle = -18 * (1 - slide) + 20 * Curve.wobble(Curve.progress(t, Beat.swing), cycles: 1.6)
        // Pegged, the card bobs with the line, but never so far that its swinging lower
        // corner leaves the frame: the menu bar would clip it.
        let bob = slide < 1 ? 0.9 * p.sag : min(0.9 * p.sag, bottomRoom - cornerDrop(angle))
        p.card = Card(
            dx: 13 * (1 - slide),
            dy: bob,
            angle: angle,
            fill: Curve.easeInOut(Curve.progress(t, Beat.develop))
                - Curve.easeInOut(Curve.progress(t, Beat.drain)),
            check: Curve.easeOut(Curve.progress(t, Beat.checkOn))
                - Curve.easeIn(Curve.progress(t, Beat.checkOff)),
            opacity: t < Beat.slideIn.lowerBound ? 0 : 1)
        // Ending anywhere but on the picture: as the fill drains, the card takes the resting
        // card's style and hang (for attention, tilted, with "!"). The picture is exactly
        // what this leaves alone.
        if to != .idle {
            let end = restingCard(to)
            let u = Curve.easeInOut(Curve.progress(t, Beat.drain))
            p.card.dash = Curve.mix(0, end.dash, u)
            p.card.picture = Curve.mix(1, end.picture, u)
            p.card.bang = Curve.mix(0, end.bang, u)
            p.card.angle += Curve.mix(0, end.angle, u)
            p.card.dy = min(p.card.dy + Curve.mix(0, end.dy, u), bottomRoom - cornerDrop(p.card.angle))
        }
        return p
    }

    /// The card a resting state shows.
    static func restingCard(_ state: StatusIconState) -> Card {
        pose(state).card
    }

    // MARK: Other moments

    /// Beats of the attention moment: the card drops off level, swings past its tilt and
    /// settles, the "!" fading in as the picture fades out. Once, when something first needs
    /// attention; it ends exactly on the attention pose.
    /// Like every moment's beats, they end by its last frame, one frame before its length,
    /// so that frame is exactly at rest.
    enum AttentionBeat {
        static let tilt = 0.0...0.15
        static let swing = 0.15...0.85
        static let jolt = 0.0...0.6
        static let mark = 0.3...0.5
        /// How far past its rest the card swings, in degrees: to about twice the tilt.
        static let swingAngle: Double = 12
    }

    static func attentionPose(at t: TimeInterval, from: StatusIconState) -> Pose {
        var p = Pose()
        // The line takes the jolt, a little.
        p.sag = 1.2 * Curve.wobble(Curve.progress(t, AttentionBeat.jolt), cycles: 1)
        let tilt = Curve.easeOut(Curve.progress(t, AttentionBeat.tilt))
        let angle = attentionAngle * tilt
            + AttentionBeat.swingAngle * Curve.wobble(Curve.progress(t, AttentionBeat.swing), cycles: 1.5)
        let start = restingCard(from), end = restingCard(.attention)
        let u = Curve.easeInOut(Curve.progress(t, AttentionBeat.mark))
        p.card = Card(
            dy: min(attentionLift * tilt, bottomRoom - cornerDrop(angle)),
            angle: angle,
            dash: Curve.mix(start.dash, end.dash, u),
            picture: Curve.mix(start.picture, end.picture, u),
            bang: Curve.mix(start.bang, end.bang, u))
        return p
    }

    /// Beats of pausing: the picture fades out of the card while its outline breaks into
    /// dashes from the bottom.
    enum PauseBeat {
        static let fade = 0.0...0.3
        static let breakUp = 0.1...0.55
    }

    static func pausePose(at t: TimeInterval) -> Pose {
        Pose(card: Card(
            dash: Curve.easeInOut(Curve.progress(t, PauseBeat.breakUp)),
            picture: 1 - Curve.easeInOut(Curve.progress(t, PauseBeat.fade))))
    }

    /// Beats of resuming: the peg opens, the outline joins up from the top, the picture
    /// develops, and the peg bites again with the copy animation's clamp and bounce (its
    /// shut and bounce beats, moved earlier).
    enum ResumeBeat {
        static let shift = 0.34
        static let pegOpen = Beat.pegOpen
        static let join = 0.08...0.4
        static let develop = 0.2...0.5
        static let pegShut = (Beat.pegShut.lowerBound - shift)...(Beat.pegShut.upperBound - shift)
        static let clampBounce = (Beat.clampBounce.lowerBound - shift)...(Beat.clampBounce.upperBound - shift)
    }

    static func resumePose(at t: TimeInterval) -> Pose {
        var p = Pose()
        let bounce = Curve.wobble(Curve.progress(t, ResumeBeat.clampBounce), cycles: 1.5)
        p.pegLift = 1.3 * Curve.easeOut(Curve.progress(t, ResumeBeat.pegOpen))
            * (1 - Curve.easeIn(Curve.progress(t, ResumeBeat.pegShut)))
            - 0.9 * bounce
        p.pegSquash = 1 - 0.3 * bounce
        p.card = Card(
            dash: 1 - Curve.easeInOut(Curve.progress(t, ResumeBeat.join)),
            picture: Curve.easeInOut(Curve.progress(t, ResumeBeat.develop)))
        return p
    }

    /// How far the resting card's outline may move down and stay inside the frame.
    static let bottomRoom = canvas.height - (card.maxY + stroke / 2)

    /// How far the lower corners of the card, turned `angle` degrees around the pivot, sink
    /// below where they rest.
    static func cornerDrop(_ angle: Double) -> CGFloat {
        let theta = angle * .pi / 180
        let y = card.maxY - pivot.y
        return [card.minX - pivot.x, card.maxX - pivot.x]
            .map { x in x * CGFloat(sin(theta)) + y * CGFloat(cos(theta)) - y }
            .max() ?? 0
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
                          control: CGPoint(x: 11, y: lineY + 0.3 + 2 * pose.sag))
        context.saveGState()
        context.setAlpha(lineOpacity)
        stroke(line, lineWeight, in: context)
        context.restoreGState()

        if let old = pose.old { drawCard(old, in: context) }
        drawCard(pose.card, in: context)

        // The peg, in front: a gap around it, the body, the spring hole.
        // Opening lifts the clamp's jaw off the card: the peg shortens from below while its
        // top stays put, so it never rises past the frame (a lift of the whole peg poked
        // 0.75 pt out of it and was clipped). Biting (a negative lift, the clamp's bounce)
        // moves it down and squashes it from below.
        let open = max(0, pose.pegLift), bite = max(0, -pose.pegLift)
        var pegTransform = scale(1, (peg.height - open) / peg.height, around: CGPoint(x: 11, y: peg.minY))
            .concatenating(CGAffineTransform(translationX: 0, y: bite))
            .concatenating(scale(1, pose.pegSquash, around: CGPoint(x: 11, y: peg.maxY + bite)))
        let body = CGPath(roundedRect: peg, cornerWidth: pegRadius, cornerHeight: pegRadius,
                          transform: &pegTransform)
        erase(body.copy(strokingWithWidth: pegGap, lineCap: .round, lineJoin: .round, miterLimit: 10), in: context)
        context.addPath(body)
        context.fillPath()
        let hole = CGPath(ellipseIn: CGRect(x: spring.x - 0.6, y: spring.y - 0.6, width: 1.2, height: 1.2),
                          transform: &pegTransform)
        erase(hole, in: context)

        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// One card, at the card's place in the canvas. The size tests measure the card on its own.
    static func drawCard(_ card: Card, in context: CGContext) {
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
        drawOutline(outline, dash: card.dash, in: context)
        if card.bang > 0 {
            let mark = onCard(0.5, 0)
            context.saveGState()
            context.setAlpha(card.bang)
            context.addPath(bang(centerX: mark.x, top: onCard(0.5, 0.24).y, bottom: onCard(0.5, 0.874).y,
                                 width: 1.6 * artScale))
            context.fillPath()
            context.restoreGState()
        }
        if card.picture > 0 {
            // The picture: a sun and one bold peak standing on the card's edge. Finer detail
            // (a second ridge, a stroked outline) turns to mush at 1x.
            // Faded as one layer, so the sun and the peak never darken where they meet.
            let fading = card.picture < 1
            context.saveGState()
            if fading {
                context.setAlpha(card.picture)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            context.addPath(outline)
            context.clip()
            let sun = onCard(0.26, 0.37), sunRadius = 1.1 * artScale
            context.addEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: 2 * sunRadius, height: 2 * sunRadius))
            let peak = CGMutablePath()
            peak.move(to: onCard(0.06, 1.05))
            peak.addLine(to: onCard(0.555, 0.43))
            peak.addLine(to: onCard(1.0, 0.87))
            peak.addLine(to: onCard(1.0, 1.05))
            peak.closeSubpath()
            context.addPath(peak)
            context.fillPath()
            if fading { context.endTransparencyLayer() }
            context.restoreGState()
        }

        if card.fill > 0 {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let h = (Self.card.height + 1) * card.fill
            context.fill(CGRect(x: Self.card.minX - 1, y: Self.card.maxY + 0.5 - h, width: Self.card.width + 2, height: h))
            context.restoreGState()
        }
        if card.check > 0 {
            // The old check's proportions, scaled with the card's height around its middle.
            let centre = onCard(0.5, 0.5)
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: centre.x + (x - 11) * artScale, y: centre.y + (y - 9.575) * artScale)
            }
            let check = CGMutablePath()
            check.move(to: at(8.0, 10.2))
            check.addLine(to: at(10.2, 12.3))
            check.addLine(to: at(14.0, 8.2))
            erase(trimmed(check, to: card.check).copy(strokingWithWidth: 1.6 * artScale, lineCap: .round,
                                                       lineJoin: .round, miterLimit: 10), in: context)
        }
    }

    /// The card's outline: solid, dashed (paused), or on its way between them, dashed below a
    /// line that rises from the card's bottom edge as `dash` goes from 0 to 1.
    private static func drawOutline(_ outline: CGPath, dash: Double, in context: CGContext) {
        let dashed = outline.copy(dashingWithPhase: 0, lengths: [1.6, 1.5])
        guard dash > 0 else { return stroke(outline, stroke, in: context) }
        guard dash < 1 else { return stroke(dashed, stroke, in: context) }
        let span = card.insetBy(dx: -stroke, dy: -stroke)
        let split = span.maxY - span.height * dash
        let wide = span.insetBy(dx: -4, dy: -4)
        context.saveGState()
        context.clip(to: CGRect(x: wide.minX, y: wide.minY, width: wide.width, height: split - wide.minY))
        stroke(outline, stroke, in: context)
        context.restoreGState()
        context.saveGState()
        context.clip(to: CGRect(x: wide.minX, y: split, width: wide.width, height: wide.maxY - split))
        stroke(dashed, stroke, in: context)
        context.restoreGState()
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

    @MainActor private static var images: [ImageKey: NSImage] = [:]

    /// The template image of `pose`, drawn at whatever scale it is displayed (crisp at 1x
    /// and 2x). Cached: the moments have a fixed set of frames. `scale` draws a larger Peg
    /// (the tour's) from the same drawing: `scale` times the canvas, just as crisp.
    @MainActor
    static func image(_ pose: Pose, scale: CGFloat = 1) -> NSImage {
        let key = ImageKey(pose: pose, scale: scale)
        if let image = images[key] { return image }
        let image = NSImage(size: CGSize(width: canvas.width * scale, height: canvas.height * scale), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            draw(pose, in: context)
            return true
        }
        image.isTemplate = true
        images[key] = image
        return image
    }

    private struct ImageKey: Hashable {
        let pose: Pose
        let scale: CGFloat
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
        /// From `a` at 0 to `b` at 1, exactly `b` at the end so a moment's last frame is at rest.
        static func mix(_ a: Double, _ b: Double, _ u: Double) -> Double {
            u >= 1 ? b : a + (b - a) * u
        }
        static func mix(_ a: CGFloat, _ b: CGFloat, _ u: Double) -> CGFloat {
            u >= 1 ? b : a + (b - a) * CGFloat(u)
        }
    }
}
