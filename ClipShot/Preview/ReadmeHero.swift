#if DEBUG
import AppKit
import SwiftUI

/// Renders the README's hero animation frame by frame, off screen: ClipShot's one key moment
/// on a small demo desktop. ⇧⌘4 and a selection over a demo window, ClipShot's floating
/// preview arriving with its Copied badge, Peg's copy animation in the menu bar (and enlarged
/// in a loupe below it), then ⌘V pasting the picture into a demo note. Debug builds only;
/// `scripts/readme-hero.sh` runs it and turns the frames into a GIF and an MP4.
///
/// Deterministic: every frame is a pure function of its time. Peg is drawn by its own
/// `Peg.pose(at:)`, the preview's arrival, image landing and timed exit come from the same
/// `Design.Motion` springs the app animates with (as `PreviewMotionSheet` does), and the
/// preview is the real `PreviewCard`. The screenshot shown on the preview and pasted into the
/// note is the selected region of the demo window, rendered at 2x.
///
/// Nothing here reads or writes the screenshot settings, folder, clipboard or preferences of
/// this Mac, and nothing is captured from the screen: the window is off screen and drawn
/// into a bitmap.
@MainActor
enum ReadmeHero {
    static let environmentKey = "CLIPSHOT_README_HERO"
    static let schemeKey = "CLIPSHOT_README_HERO_SCHEME"

    /// The directory the frames go to, when the hero was asked for.
    static var requestedOutput: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var scheme: ColorScheme {
        ProcessInfo.processInfo.environment[schemeKey] == "dark" ? .dark : .light
    }

    static let fps: Double = 30
    /// The demo screen, in points. Small, so the real UI's 11 pt text reads at README width.
    static let stage = CGSize(width: 600, height: 400)
    /// Pixels per point of the rendered frames: 1920 x 1280, downscaled to 960 x 640.
    static let pixelScale: CGFloat = 3.2

    static func run(into output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let scheme = scheme
        let frames = output.appendingPathComponent("frames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        } catch {
            ScreenshotHarness.fail("\(error)")
        }

        let shot = Scene.screenshot(scheme)
        let file = CaptureFile(
            url: URL(fileURLWithPath: "/Demo/\(DemoContent.screenshotName)"), created: DemoContent.renderNow,
            modified: DemoContent.renderNow, size: 120_000, resourceID: Data(), isScreenshot: true)
        let item = PreviewItem(id: UUID(), file: file, image: shot)
        let clock = HeroClock()

        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: HeroStage(clock: clock, item: item, shot: shot, scheme: scheme))
        hosting.appearance = appearance
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: stage.width, height: stage.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()

        // The preview card is in the tree from the first frame (off stage until it arrives),
        // so its own arrival work (the image landing, the badge's bounce) runs out here, in
        // real time, before any frame is drawn; the frames then show the springs' values.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let count = Int((Beat.loop * fps).rounded())
        for index in 0..<count {
            clock.t = Double(index) / fps
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(stage.width * pixelScale), pixelsHigh: Int(stage.height * pixelScale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { ScreenshotHarness.fail("could not allocate a bitmap") }
            rep.size = stage
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = frames.appendingPathComponent(String(format: "%04d.png", index))
            guard let png = rep.representation(using: .png, properties: [:]) else {
                ScreenshotHarness.fail("could not encode frame \(index)")
            }
            do { try png.write(to: url) } catch { ScreenshotHarness.fail("\(error)") }
        }
        print("wrote \(count) frames at \(Int(fps)) fps into \(frames.path)")
        exit(0)
    }

    /// The story's beats, in seconds from the start of the loop. Peg's copy moment and the
    /// preview's arrival share one instant, as they do in the app (the copy shows both), and
    /// it falls on a frame, so Peg's frames are exactly the menu bar's 30 fps phases.
    enum Beat {
        static let shortcutKeys = 0.3...1.15
        /// ⇧⌘4 turns the pointer into the crosshair.
        static let crosshair = 0.35
        static let toCorner = 0.35...1.0
        static let drag = 1.1...1.85
        static let release = 1.9
        static let copy = 2.0
        static let loupeIn = 1.9
        static let loupeOut = copy + Design.Motion.menuBarCopy + 0.1
        static let pointerHome = 2.25...3.05
        /// ⌘V while Peg's check is on: halfway between `Peg.Beat.checkOn` ending and
        /// `Peg.Beat.checkOff` starting, so the paste follows the copy's confirmation.
        static let paste = copy + (Peg.Beat.checkOn.upperBound + Peg.Beat.checkOff.lowerBound) / 2
        static let pasteKeys = (paste - 0.1)...(paste + 0.7)
        static let pasteFade = 0.15
        /// The preview's 5 s, then its timed exit.
        static let leave = copy + Double(FloatingPreviews.defaultLifetime.components.seconds)
        /// The note goes back to how it started, a few frames before the loop begins again,
        /// so the last frames are the first one and the seam does not show.
        static let reset = 7.25...7.6
        static let loop = 7.7
    }
}

@MainActor
@Observable
private final class HeroClock {
    var t: Double = 0
}

/// Geometry and pieces of the demo desktop, in stage points (y down).
@MainActor
private enum Scene {
    static let menuBarHeight: CGFloat = 24
    static let note = CGRect(x: 20, y: 44, width: 280, height: 336)
    static let analytics = CGRect(x: 318, y: 128, width: 264, height: 164)
    static let titleBar: CGFloat = 28
    /// What the user selects: the chart card of the analytics window, with a little room.
    static let selection = CGRect(x: 324, y: 162, width: 252, height: 124)
    /// The pointer rests here, in the note, between takes.
    static let home = CGPoint(x: 236, y: 132)
    /// Peg's place in the menu bar, its centre.
    static let pegCentre = CGPoint(x: 404, y: menuBarHeight / 2)
    static let loupeDiameter: CGFloat = 88
    static let loupeZoom: CGFloat = 3
    /// Where key presses are said: the wallpaper right of the loupe.
    static let keys = CGPoint(x: 522, y: 78)

    /// The selected region of the analytics window as macOS would save it: 2x pixels.
    static func screenshot(_ scheme: ColorScheme) -> CGImage {
        let renderer = ImageRenderer(content: AnalyticsWindow(active: false, scheme: scheme)
            .frame(width: analytics.width, height: analytics.height)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let window = renderer.cgImage else { ScreenshotHarness.fail("could not render the demo window") }
        let crop = CGRect(
            x: (selection.minX - analytics.minX) * 2, y: (selection.minY - analytics.minY) * 2,
            width: selection.width * 2, height: selection.height * 2)
        guard let shot = window.cropping(to: crop) else { ScreenshotHarness.fail("could not crop the screenshot") }
        return shot
    }

    static func progress(_ t: Double, _ beat: ClosedRange<Double>) -> Double {
        Peg.Curve.progress(t, beat)
    }
}

private struct HeroStage: View {
    let clock: HeroClock
    let item: PreviewItem
    let shot: CGImage
    let scheme: ColorScheme

    private typealias Beat = ReadmeHero.Beat

    var body: some View {
        let t = clock.t
        ZStack(alignment: .topLeading) {
            Wallpaper(scheme: scheme)
            AnalyticsWindow(active: false, scheme: scheme)
                .frame(width: Scene.analytics.width, height: Scene.analytics.height)
                .windowChrome(active: false, scheme: scheme)
                .offset(x: Scene.analytics.minX, y: Scene.analytics.minY)
            NoteWindow(t: t, shot: shot, scheme: scheme)
                .frame(width: Scene.note.width, height: Scene.note.height)
                .windowChrome(active: true, scheme: scheme)
                .offset(x: Scene.note.minX, y: Scene.note.minY)
            MenuBar(pose: pegPose(t), scheme: scheme)
            preview(t)
            Keys(text: "⇧⌘4", t: t, beat: Beat.shortcutKeys)
            Keys(text: "⌘V", t: t, beat: Beat.pasteKeys)
            selection(t)
            Loupe(t: t, pose: pegPose(t), scheme: scheme)
            Pointer(t: t, scheme: scheme)
        }
        .frame(width: ReadmeHero.stage.width, height: ReadmeHero.stage.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, scheme)
        .environment(SettingsRouter())
        .environment(UpdateStatus())
    }

    /// Peg in the menu bar: the copy animation from `Beat.copy`, at rest otherwise.
    private func pegPose(_ t: Double) -> Peg.Pose {
        let dt = t - Beat.copy
        guard dt >= 0, dt < Design.Motion.menuBarCopy else { return Peg.pose(.idle) }
        return Peg.pose(at: dt)
    }

    /// ClipShot's floating preview at the screen's bottom right: arrives from the edge with
    /// `Design.Motion.arrive` (the image landing with `land`), leaves on time sliding back with
    /// `leave`, as `PreviewStack`'s transitions do.
    private func preview(_ t: Double) -> some View {
        let size = PreviewCardMetrics.size(for: item.image)
        let travel = size.width + PreviewCardMetrics.screenInset + 20
        let since = t - Beat.copy
        let arrive = since < 0 ? 0 : Design.Motion.arriveSpring.value(target: 1.0, time: since)
        let land = since < Design.Motion.landDelay
            ? 0 : Design.Motion.landSpring.value(target: 1.0, time: since - Design.Motion.landDelay)
        let away = t < Beat.leave ? 0 : Spring(duration: 0.24, bounce: 0).value(target: 1.0, time: t - Beat.leave)
        let x = (1 - arrive) * travel + away * travel
        return PreviewCard(
            item: item, actions: .inert,
            imageScale: PreviewCard.arrivalImageScale + (1 - PreviewCard.arrivalImageScale) * land)
            .offset(x: x)
            .opacity(1 - away)
            .frame(width: size.width, height: size.height)
            .offset(
                x: ReadmeHero.stage.width - PreviewCardMetrics.screenInset - size.width,
                y: ReadmeHero.stage.height - PreviewCardMetrics.screenInset - size.height)
    }

    /// The ⇧⌘4 selection while it is being dragged.
    @ViewBuilder private func selection(_ t: Double) -> some View {
        if t >= Beat.drag.lowerBound, t < Beat.release {
            let rect = selectionRect(t)
            Rectangle()
                .fill(Color(white: 0.5, opacity: 0.22))
                .overlay(Rectangle().strokeBorder(Color(white: 0.55, opacity: 0.9), lineWidth: 0.75))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func selectionRect(_ t: Double) -> CGRect {
        let u = Peg.Curve.easeInOut(Scene.progress(t, Beat.drag))
        let s = Scene.selection
        return CGRect(x: s.minX, y: s.minY, width: max(1, s.width * u), height: max(1, s.height * u))
    }
}

// MARK: Desktop

private struct Wallpaper: View {
    let scheme: ColorScheme

    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.24, green: 0.09, blue: 0.10), Color(red: 0.27, green: 0.16, blue: 0.05)]
                       : [Color(red: 0.99, green: 0.84, blue: 0.80), Color(red: 0.99, green: 0.91, blue: 0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: ReadmeHero.stage.width, height: ReadmeHero.stage.height)
    }
}

private struct MenuBar: View {
    let pose: Peg.Pose
    let scheme: ColorScheme

    private var ink: Color { scheme == .dark ? .white : Color.black.opacity(0.85) }

    var body: some View {
        ZStack {
            Rectangle().fill(scheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.28))
            HStack(spacing: 0) {
                Image(systemName: "apple.logo").font(.system(size: 14)).padding(.trailing, 18)
                Text(verbatim: "Notebook").fontWeight(.bold).padding(.trailing, 16)
                ForEach(["File", "Edit", "Format", "View"], id: \.self) { title in
                    Text(verbatim: title).padding(.trailing, 16)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(nsImage: Peg.image(pose))
                    .renderingMode(.template)
                    .frame(width: Peg.canvas.width, height: Peg.canvas.height)
                    .padding(.trailing, 14)
                Image(systemName: "wifi").padding(.trailing, 14)
                Image(systemName: "switch.2").padding(.trailing, 14)
                Text(verbatim: "Tue Oct 20  9:41 AM")
            }
            .padding(.trailing, 14)
        }
        .font(.system(size: 13))
        .foregroundStyle(ink)
        .frame(width: ReadmeHero.stage.width, height: Scene.menuBarHeight)
    }
}

/// A window frame as macOS 26 draws one: rounded corners, a hairline, a shadow (deeper for
/// the key window) and the traffic lights (grey when inactive).
private struct WindowChrome: ViewModifier {
    let active: Bool
    let scheme: ColorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach(lights.indices, id: \.self) { Circle().fill(lights[$0]).frame(width: 12, height: 12) }
                }
                .padding(.leading, 12)
                .frame(height: Scene.titleBar)
            }
            .background(shape.fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.985)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(active ? 0.22 : 0.12), radius: active ? 16 : 9, y: active ? 8 : 4)
    }

    private var lights: [Color] {
        guard active else {
            let grey = scheme == .dark ? Color(white: 0.36) : Color(white: 0.83)
            return [grey, grey, grey]
        }
        return [Color(red: 1.0, green: 0.37, blue: 0.34), Color(red: 1.0, green: 0.74, blue: 0.18),
                Color(red: 0.16, green: 0.79, blue: 0.25)]
    }
}

private extension View {
    func windowChrome(active: Bool, scheme: ColorScheme) -> some View {
        modifier(WindowChrome(active: active, scheme: scheme))
    }
}

/// The window the screenshot is taken of: an invented analytics app with one chart card, in
/// the colours of the demo window the other README pictures show.
private struct AnalyticsWindow: View {
    let active: Bool
    let scheme: ColorScheme

    private let bars: [CGFloat] = [0.42, 0.58, 0.51, 0.72, 0.66, 0.84, 0.93]
    private let coral = Color(red: 0.937, green: 0.396, blue: 0.329)
    private let amber = Color(red: 0.973, green: 0.643, blue: 0.247)

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "Analytics")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Scene.titleBar)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Signups this week")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: "1,284").font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text(verbatim: "+12 %")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.16, green: 0.62, blue: 0.30))
                        }
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(bars.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(LinearGradient(colors: [amber, coral], startPoint: .bottom, endPoint: .top))
                                .frame(height: 44 * bars[index])
                            Text(verbatim: ["M", "T", "W", "T", "F", "S", "S"][index])
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }
            .padding(12)
            .frame(width: 240, height: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(scheme == .dark ? Color(white: 0.23) : .white))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.955))
    }
}

/// The note the picture is pasted into. Before the paste the caret waits under the text;
/// after it the picture sits at the caret and the caret moves under it. At the end of the
/// loop the note crossfades back to how it started.
private struct NoteWindow: View {
    let t: Double
    let shot: CGImage
    let scheme: ColorScheme

    private typealias Beat = ReadmeHero.Beat

    var body: some View {
        let reset = Scene.progress(t, Beat.reset)
        let pasted = t >= Beat.paste && t < Beat.reset.upperBound
        // The picture and the caret under it fade in on the paste and out on the reset; the
        // text stays as it is, so it never dims while two states overlap.
        let picture = pasted ? min(1, (t - Beat.paste) / Beat.pasteFade) * (1 - reset) : 0
        VStack(spacing: 0) {
            Text(verbatim: "Weekly update")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: Scene.titleBar)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Weekly update").font(.system(size: 18, weight: .bold))
                Text(verbatim: "Signups are up again this week:").font(.system(size: 13))
                ZStack(alignment: .topLeading) {
                    caret.opacity(pasted ? reset : 1)
                    if pasted {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(decorative: shot, scale: 2)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 224)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                                .padding(.top, 4)
                            caret
                        }
                        .opacity(picture)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(scheme == .dark ? Color(white: 0.12) : .white)
        }
    }

    /// The text caret, blinking as macOS's does: 7 blinks per loop, so the seam does not show.
    private var caret: some View {
        let period = Beat.loop / 7
        let on = t.truncatingRemainder(dividingBy: period) < period * 0.55
        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5, height: 16)
            .opacity(on ? 1 : 0)
    }
}

/// A key press, said on screen while it is held, so the viewer knows what happened.
private struct Keys: View {
    let text: String
    let t: Double
    let beat: ClosedRange<Double>

    var body: some View {
        let fadeIn = Scene.progress(t, beat.lowerBound...(beat.lowerBound + 0.12))
        let fadeOut = Scene.progress(t, (beat.upperBound - 0.2)...beat.upperBound)
        let opacity = fadeIn * (1 - fadeOut)
        Text(verbatim: text)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.68)))
            .opacity(opacity)
            .frame(width: 120, height: 40)
            .offset(x: Scene.keys.x - 60, y: Scene.keys.y - 20)
    }
}

/// Peg enlarged three times in a round loupe that hangs from its place in the menu bar,
/// shown while the copy animation plays: the 22 x 16 pt glyph is too small to follow at
/// README size. The same pose as the menu bar's, frame for frame.
private struct Loupe: View {
    let t: Double
    let pose: Peg.Pose
    let scheme: ColorScheme

    private typealias Beat = ReadmeHero.Beat

    var body: some View {
        let inSpring = Spring(duration: 0.35, bounce: 0.18)
        let shown = t < Beat.loupeIn ? 0 : inSpring.value(target: 1.0, time: t - Beat.loupeIn)
        let gone = Peg.Curve.easeIn(Scene.progress(t, Beat.loupeOut...(Beat.loupeOut + 0.2)))
        let d = Scene.loupeDiameter
        let top = Scene.menuBarHeight + 10
        ZStack {
            Circle().fill(scheme == .dark ? Color(white: 0.2) : Color(red: 0.995, green: 0.93, blue: 0.9))
            Image(nsImage: Peg.image(pose, scale: Scene.loupeZoom))
                .renderingMode(.template)
                .foregroundStyle(scheme == .dark ? Color.white : Color.black.opacity(0.85))
            Circle().strokeBorder(Color.white.opacity(scheme == .dark ? 0.35 : 0.95), lineWidth: 2)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .overlay(alignment: .top) {
            // The tie to the glyph it magnifies.
            Rectangle()
                .fill(Color.white.opacity(scheme == .dark ? 0.35 : 0.95))
                .frame(width: 1.5, height: 8)
                .offset(y: -8)
        }
        .scaleEffect(max(0.01, (0.6 + 0.4 * shown) * (1 - 0.1 * gone)), anchor: .top)
        .opacity(min(1, shown * 1.6) * (1 - gone))
        .frame(width: d, height: d)
        .offset(x: Scene.pegCentre.x - d / 2, y: top)
        .allowsHitTesting(false)
    }
}

/// The pointer: the system arrow, or ⇧⌘4's crosshair with its coordinates, and the
/// selection's size while dragging.
private struct Pointer: View {
    let t: Double
    let scheme: ColorScheme

    private typealias Beat = ReadmeHero.Beat

    private var position: CGPoint {
        let corner = CGPoint(x: Scene.selection.minX, y: Scene.selection.minY)
        let end = CGPoint(x: Scene.selection.maxX, y: Scene.selection.maxY)
        if t < Beat.toCorner.upperBound {
            return mix(Scene.home, corner, Peg.Curve.easeInOut(Scene.progress(t, Beat.toCorner)))
        }
        if t < Beat.drag.upperBound {
            return mix(corner, end, Peg.Curve.easeInOut(Scene.progress(t, Beat.drag)))
        }
        return mix(end, Scene.home, Peg.Curve.easeInOut(Scene.progress(t, Beat.pointerHome)))
    }

    private func mix(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    var body: some View {
        let p = position
        if t >= Beat.crosshair, t < Beat.release {
            crosshair(at: p)
        } else {
            let cursor = NSCursor.arrow
            Image(nsImage: cursor.image)
                .offset(x: p.x - cursor.hotSpot.x, y: p.y - cursor.hotSpot.y)
        }
    }

    private func crosshair(at p: CGPoint) -> some View {
        let dragging = t >= Beat.drag.lowerBound
        let label = dragging
            ? "\(Int((p.x - Scene.selection.minX).rounded()))  \(Int((p.y - Scene.selection.minY).rounded()))"
            : "\(Int(p.x.rounded()))  \(Int(p.y.rounded()))"
        return ZStack(alignment: .topLeading) {
            ZStack {
                Rectangle().fill(Color.white).frame(width: 25, height: 3)
                Rectangle().fill(Color.white).frame(width: 3, height: 25)
                Rectangle().fill(Color.black).frame(width: 23, height: 1)
                Rectangle().fill(Color.black).frame(width: 1, height: 23)
            }
            .frame(width: 25, height: 25)
            Text(verbatim: label)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.black)
                .shadow(color: .white, radius: 0.5)
                .shadow(color: .white, radius: 0.5)
                .fixedSize()
                .offset(x: 24, y: 20)
        }
        .offset(x: p.x - 12.5, y: p.y - 12.5)
    }
}
#endif
