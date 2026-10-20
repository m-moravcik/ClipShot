#if DEBUG
import AppKit
import SwiftUI

/// Renders the Task 12e symbol proposals (`SymbolConcept`) for review: per concept the
/// states, the menu bar (light, dark, tinted, highlighted, 1x and 2x, beside VibeRes, Eject
/// Guard and a crop of a real menu bar), the pairing with the app icon, a frame strip of
/// the copy animation and the animation's frames for a video; plus one overview sheet.
/// Everything is drawn offscreen with explicit timestamps, never wall-clock.
///
///     CLIPSHOT_SYMBOL_CONCEPTS=<out> CLIPSHOT_SYMBOL_FRAMES=<frames> CLIPSHOT_BAR_CROP=<png> ClipShot
@MainActor
enum SymbolConceptSheets {
    static let outputKey = "CLIPSHOT_SYMBOL_CONCEPTS"
    static let framesKey = "CLIPSHOT_SYMBOL_FRAMES"
    static let barKey = "CLIPSHOT_BAR_CROP"

    static var requestedOutput: URL? { url(outputKey) }

    private static func url(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static let fps = 30.0
    /// Idle before and after the animation in the video loop.
    static let leadIn = 0.4, tail = 0.6

    static func run(into output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let bar = url(barKey).flatMap(OwnerBar.init)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for concept in SymbolConcept.allCases {
                let dir = output.appendingPathComponent(concept.slug, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try write(StatesSheet(concept: concept), dir.appendingPathComponent("states.png"))
                try write(MenuBarSheet(concept: concept, bar: bar), dir.appendingPathComponent("menubar.png"))
                try write(AppIconSheet(concept: concept), dir.appendingPathComponent("with-app-icon.png"))
                try write(CopyStripSheet(concept: concept), dir.appendingPathComponent("copy-strip.png"))
                if let frames = url(framesKey)?.appendingPathComponent(concept.slug, isDirectory: true) {
                    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
                    let count = Int(((leadIn + SymbolConcept.copyDuration + tail) * fps).rounded())
                    for i in 0..<count {
                        let t = Double(i) / fps - leadIn
                        let frame: ConceptFrame = t < 0 || t > SymbolConcept.copyDuration ? .still(.idle) : .copy(t)
                        try write(VideoFrame(concept: concept, frame: frame, t: t, bar: bar),
                                  frames.appendingPathComponent(String(format: "frame-%03d.png", i)), scale: 1)
                    }
                }
                let ink = GlyphInk.size(glyph(concept, .still(.idle), .black, scale: 2))
                print("\(concept.slug): idle ink at 2x \(ink.width) x \(ink.height) px")
            }
            try write(OverviewSheet(bar: bar), output.appendingPathComponent("overview.png"))
            let eg = GlyphInk.size(render(GlyphInk.ejectGuardLabel().foregroundStyle(Color.black), scale: 2))
            print("Eject Guard externaldrive ink at 2x \(eg.width) x \(eg.height) px")
        } catch {
            fail("\(error)")
        }
        exit(0)
    }

    // MARK: Rendering

    static func render(_ view: some View, scale: CGFloat) -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { fail("render failed") }
        return image
    }

    static func glyph(_ concept: SymbolConcept, _ frame: ConceptFrame, _ color: Color, scale: CGFloat) -> CGImage {
        render(ConceptGlyph(concept: concept, frame: frame).foregroundStyle(color), scale: scale)
    }

    /// VibeRes's label: the symbol at the menu bar's 13 pt.
    static func vibeRes(_ color: Color, scale: CGFloat) -> CGImage {
        render(Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 13)).foregroundStyle(color), scale: scale)
    }

    static func ejectGuard(_ color: Color, scale: CGFloat) -> CGImage {
        render(GlyphInk.ejectGuardLabel().foregroundStyle(color), scale: scale)
    }

    private static func write(_ view: some View, _ url: URL, scale: CGFloat = 2) throws {
        let rep = NSBitmapImageRep(cgImage: render(view, scale: scale))
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode \(url.path)") }
        try png.write(to: url)
        print("wrote \(url.path)  \(rep.pixelsWide)x\(rep.pixelsHigh) px")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("symbol concepts: \(message)\n".utf8))
        exit(1)
    }

    /// The app icon as the system draws it, rasterised up front: `Image(nsImage:)` of the
    /// workspace icon comes out dimmed and blurred under `ImageRenderer`.
    static let appIcon: CGImage = {
        let pixels = 512
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fail("could not allocate a bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage else { fail("app icon render failed") }
        return cgImage
    }()

    static let stills: [(String, StatusIconState)] = [
        ("idle", .idle), ("copied", .copied), ("paused", .paused), ("attention", .attention),
    ]
}

// MARK: - Pieces

/// A bitmap shown pixel for pixel: `zoom` sheet pixels per image pixel, at the sheet's scale.
private struct Px: View {
    let image: CGImage
    var zoom: CGFloat = 1
    var sheetScale: CGFloat = 2

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)
            .frame(width: CGFloat(image.width) * zoom / sheetScale, height: CGFloat(image.height) * zoom / sheetScale)
    }
}

private struct BarStyle: Identifiable {
    let id: String
    let background: AnyShapeStyle
    let ink: Color
    var pill: Color?

    static var light: BarStyle { BarStyle(id: "Light", background: AnyShapeStyle(Color(white: 0.94)), ink: .black) }
    static var dark: BarStyle { BarStyle(id: "Dark", background: AnyShapeStyle(Color(white: 0.13)), ink: .white) }
    static var tinted: BarStyle { BarStyle(
        id: "Tinted wallpaper",
        background: AnyShapeStyle(LinearGradient(
            colors: [Color(red: 0.50, green: 0.46, blue: 0.55), Color(red: 0.36, green: 0.45, blue: 0.62),
                     Color(red: 0.30, green: 0.40, blue: 0.58)],
            startPoint: .leading, endPoint: .trailing)),
        ink: .white) }
    static var highlightedDark: BarStyle {
        BarStyle(id: "Highlighted (menu open), dark", background: dark.background, ink: .white, pill: Color.white.opacity(0.2))
    }
    static var highlightedLight: BarStyle {
        BarStyle(id: "Highlighted (menu open), light", background: light.background, ink: .black, pill: Color.black.opacity(0.1))
    }
    static var all: [BarStyle] { [light, dark, tinted, highlightedDark, highlightedLight] }
}

/// The right side of the owner's real menu bar (a 2x capture, 19.10.2026) with the old
/// ClipShot icon painted over and a concept drawn in its place.
@MainActor
private struct OwnerBar {
    let crop: CGImage
    /// One-pixel columns of the bar just left and right of the old icon's highlight, stretched
    /// over it: the real bar pixels, wallpaper tint and bottom edge included.
    let left: CGImage, right: CGImage
    let pill: Color

    /// Where the old icon sat, in points of the 2x crop.
    static let center = CGPoint(x: 44.25, y: 19.2)
    static let pillRect = CGRect(x: 26.5, y: 7.5, width: 36, height: 23.75)
    /// The patch over the old icon and its highlight, in points.
    static let patch = (x: 25.5, width: 38.0)

    init?(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data), let crop = rep.cgImage,
              let left = crop.cropping(to: CGRect(x: 50, y: 0, width: 1, height: crop.height)),
              let right = crop.cropping(to: CGRect(x: 127, y: 0, width: 1, height: crop.height))
        else { return nil }
        self.crop = crop
        self.left = left
        self.right = right
        pill = Color(nsColor: rep.colorAt(x: 60, y: 40) ?? .gray)
    }

    var size: CGSize { CGSize(width: CGFloat(crop.width) / 2, height: CGFloat(crop.height) / 2) }

    @ViewBuilder
    func view(_ concept: SymbolConcept?, _ frame: ConceptFrame, highlighted: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: crop, scale: 2)
            if let concept {
                ZStack {
                    Image(decorative: left, scale: 2).resizable()
                    Image(decorative: right, scale: 2).resizable()
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
                }
                .frame(width: Self.patch.width, height: size.height)
                .offset(x: Self.patch.x)
                if highlighted {
                    Capsule().fill(pill)
                        .frame(width: Self.pillRect.width, height: Self.pillRect.height)
                        .offset(x: Self.pillRect.minX, y: Self.pillRect.minY)
                }
                ConceptGlyph(concept: concept, frame: frame)
                    .foregroundStyle(Color.white)
                    .offset(x: Self.center.x - 11, y: Self.center.y - 8)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    func image(_ concept: SymbolConcept?, _ frame: ConceptFrame, highlighted: Bool) -> CGImage {
        SymbolConceptSheets.render(view(concept, frame, highlighted: highlighted), scale: 2)
    }
}

private struct Caption: View {
    let text: String
    var size: CGFloat = 10
    var weight: Font.Weight = .regular

    var body: some View {
        Text(verbatim: text).font(.system(size: size, weight: weight)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Header: View {
    let concept: SymbolConcept
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caption(text: "\(concept.rawValue)  \(concept.name) - \(subtitle)", size: 16, weight: .semibold)
            Caption(text: concept.pitch, size: 11).foregroundStyle(.secondary)
        }
    }
}

/// A menu bar strip: the siblings, then the concept's frames, at one scale. `zoom` is the
/// sheet pixels per glyph pixel: 2 for 1x glyphs and 1 for 2x glyphs show the same size.
private struct BarStrip: View {
    let style: BarStyle
    let concept: SymbolConcept
    let frames: [ConceptFrame]
    let scale: CGFloat
    var siblings = true

    var body: some View {
        let zoom = 2 / scale
        HStack(spacing: 12) {
            if siblings {
                Px(image: SymbolConceptSheets.vibeRes(style.ink, scale: scale), zoom: zoom)
                Px(image: SymbolConceptSheets.ejectGuard(style.ink, scale: scale), zoom: zoom)
            }
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                Px(image: SymbolConceptSheets.glyph(concept, frame, style.ink, scale: scale), zoom: zoom)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background {
                        if index == 0, let pill = style.pill { Capsule().fill(pill) }
                    }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(style.background)
    }
}

// MARK: - states.png

private struct StatesSheet: View {
    let concept: SymbolConcept

    var body: some View {
        let ink = GlyphInk.size(SymbolConceptSheets.glyph(concept, .still(.idle), .black, scale: 2))
        let eg = GlyphInk.size(SymbolConceptSheets.render(GlyphInk.ejectGuardLabel().foregroundStyle(Color.black), scale: 2))
        VStack(alignment: .leading, spacing: 12) {
            Header(concept: concept, subtitle: "states")
            Caption(text: "Template glyph in the fixed 22 x 16 pt status item frame. Idle ink at 2x: \(ink.width) x \(ink.height) px "
                + "(Eject Guard's externaldrive: \(eg.width) x \(eg.height) px). Copied is the pose the flash holds; with Reduce "
                + "Motion it is held as is for 1.4 s, no movement. Rows: 1x as on a non-Retina display, 2x actual pixels, 2x zoomed 6x.")
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Spacer().frame(width: 90)
                ForEach(SymbolConceptSheets.stills, id: \.0) { name, _ in
                    Caption(text: name, size: 11, weight: .semibold).frame(width: 150)
                }
            }
            ForEach([BarStyle.light, BarStyle.dark, BarStyle.tinted]) { style in
                VStack(alignment: .leading, spacing: 8) {
                    Caption(text: style.id, size: 11, weight: .semibold).foregroundStyle(style.ink)
                    row(style, "1x", scale: 1, zoom: 2)
                    row(style, "2x", scale: 2, zoom: 1)
                    row(style, "2x zoom", scale: 2, zoom: 6)
                }
                .padding(10)
                .background(style.background)
            }
        }
        .padding(16)
        .frame(width: 720, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func row(_ style: BarStyle, _ label: String, scale: CGFloat, zoom: CGFloat) -> some View {
        HStack(spacing: 0) {
            Caption(text: label).foregroundStyle(style.ink).frame(width: 80, alignment: .leading)
            ForEach(SymbolConceptSheets.stills, id: \.0) { _, state in
                Px(image: SymbolConceptSheets.glyph(concept, .still(state), style.ink, scale: scale), zoom: zoom)
                    .frame(width: 150)
            }
        }
    }
}

// MARK: - menubar.png

private struct MenuBarSheet: View {
    let concept: SymbolConcept
    let bar: OwnerBar?

    private var frames: [ConceptFrame] { SymbolConceptSheets.stills.map { .still($0.1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(concept: concept, subtitle: "in the menu bar")
            if let bar {
                Caption(text: "In your menu bar (right side of the 19.10. capture, 2x), the old ClipShot icon replaced. Top: actual size. "
                    + "Below: zoomed 2x. Left to right: idle, idle with the menu open, copied, paused, attention.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(ownerVariants.prefix(4).enumerated()), id: \.offset) { _, variant in
                        Px(image: bar.image(concept, variant.0, highlighted: variant.1))
                    }
                }
                HStack(spacing: 10) {
                    ForEach(Array(ownerVariants.dropFirst(4).enumerated()), id: \.offset) { _, variant in
                        Px(image: bar.image(concept, variant.0, highlighted: variant.1))
                    }
                }
                let zoomed = ownerVariants.map { bar.image(concept, $0.0, highlighted: $0.1) }
                    + [bar.image(nil, .still(.idle), highlighted: false)]
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { line in
                        HStack(spacing: 10) {
                            ForEach(line * 2..<min(zoomed.count, line * 2 + 2), id: \.self) { i in
                                Px(image: zoomed[i], zoom: 2)
                            }
                        }
                    }
                    Caption(text: "Last: today, the old ClipShot icon with its menu open", size: 9).foregroundStyle(.secondary)
                }
            }
            Caption(text: "Beside VibeRes and Eject Guard. Each strip: VibeRes, Eject Guard, then idle, copied, paused, attention. "
                + "1x as on a non-Retina display (each pixel doubled), 2x actual pixels; both at the same physical size.")
                .foregroundStyle(.secondary)
            ForEach(BarStyle.all) { style in
                VStack(alignment: .leading, spacing: 4) {
                    Caption(text: style.id, size: 10, weight: .semibold)
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Caption(text: "1x", size: 9).foregroundStyle(.secondary)
                            BarStrip(style: style, concept: concept, frames: frames, scale: 1)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Caption(text: "2x", size: 9).foregroundStyle(.secondary)
                            BarStrip(style: style, concept: concept, frames: frames, scale: 2)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 720, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private var ownerVariants: [(ConceptFrame, Bool)] {
        [(.still(.idle), false), (.still(.idle), true), (.still(.copied), false), (.still(.paused), false), (.still(.attention), false)]
    }
}

// MARK: - with-app-icon.png

private struct AppIconSheet: View {
    let concept: SymbolConcept

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(concept: concept, subtitle: "with the app icon")
            HStack(spacing: 0) {
                panel(dark: false)
                panel(dark: true)
            }
        }
        .padding(16)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func panel(dark: Bool) -> some View {
        let ink: Color = dark ? .white : .black
        let style = dark ? BarStyle.dark : BarStyle.light
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 22) {
                Image(decorative: SymbolConceptSheets.appIcon, scale: 1)
                    .resizable()
                    .frame(width: 128, height: 128)
                Px(image: SymbolConceptSheets.glyph(concept, .still(.idle), ink, scale: 14), zoom: 1)
                Px(image: SymbolConceptSheets.glyph(concept, .still(.copied), ink, scale: 14), zoom: 1)
            }
            HStack(spacing: 14) {
                BarStrip(style: style, concept: concept, frames: [.still(.idle)], scale: 2)
                Image(decorative: SymbolConceptSheets.appIcon, scale: 1)
                    .resizable()
                    .frame(width: 32, height: 32)
                Caption(text: "menu bar at actual size, app icon at 32 pt", size: 9).foregroundStyle(ink.opacity(0.6))
            }
        }
        .padding(18)
        .background(dark ? Color(white: 0.11) : Color(white: 0.97))
    }
}

// MARK: - copy-strip.png

private struct CopyStripSheet: View {
    let concept: SymbolConcept

    static let times = stride(from: 0.0, through: SymbolConcept.copyDuration + 0.001, by: 0.1).map { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(concept: concept, subtitle: "copy animation, \(SymbolConcept.copyDuration) s")
            Caption(text: "\(concept.motion). From \(SymbolConcept.settleStart) s the copied pose crossfades back to idle. "
                + "Mechanism: \(concept.mechanism). Reduce Motion: the copied pose (last column) held for 1.4 s, no movement.")
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                Spacer().frame(width: 60)
                ForEach(Self.times, id: \.self) { t in
                    Caption(text: String(format: "%.1f s", t), size: 9, weight: .semibold).frame(width: 94)
                }
                Caption(text: "Reduce Motion", size: 9, weight: .semibold).frame(width: 94)
            }
            ForEach([BarStyle.dark, BarStyle.light]) { style in
                VStack(alignment: .leading, spacing: 6) {
                    row(style, "2x", scale: 2, zoom: 1)
                    row(style, "2x zoom", scale: 2, zoom: 4)
                    row(style, "1x", scale: 1, zoom: 2)
                }
                .padding(.vertical, 8)
                .background(style.background)
            }
        }
        .padding(16)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func row(_ style: BarStyle, _ label: String, scale: CGFloat, zoom: CGFloat) -> some View {
        HStack(spacing: 0) {
            Caption(text: label, size: 9).foregroundStyle(style.ink).frame(width: 60)
            ForEach(Self.times, id: \.self) { t in
                Px(image: SymbolConceptSheets.glyph(concept, .copy(t), style.ink, scale: scale), zoom: zoom).frame(width: 94)
            }
            Px(image: SymbolConceptSheets.glyph(concept, .still(.copied), style.ink, scale: scale), zoom: zoom).frame(width: 94)
        }
    }
}

// MARK: - Video frames

private struct VideoFrame: View {
    let concept: SymbolConcept
    let frame: ConceptFrame
    let t: Double
    let bar: OwnerBar?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Caption(text: "\(concept.rawValue)  \(concept.name) - copy animation", size: 28, weight: .semibold)
                Spacer()
                Caption(text: label, size: 20).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                big(.white, Color(white: 0.13))
                big(.black, Color(white: 0.92))
            }
            if let bar {
                Caption(text: "In your menu bar, shown 3x", size: 14).foregroundStyle(.secondary)
                Px(image: bar.image(concept, frame, highlighted: false), zoom: 3, sheetScale: 1)
            }
        }
        .padding(32)
        .frame(width: 1280, height: 720, alignment: .topLeading)
        .background(Color(white: 0.98))
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private var label: String {
        if case .copy(let time) = frame { return String(format: "t = %.2f s", time) }
        return t < 0 ? "idle" : "idle (after)"
    }

    private func big(_ ink: Color, _ background: Color) -> some View {
        Px(image: SymbolConceptSheets.glyph(concept, frame, ink, scale: 16), zoom: 1, sheetScale: 1)
            .frame(width: 596, height: 300)
            .background(background)
    }
}

// MARK: - overview.png

private struct OverviewSheet: View {
    let bar: OwnerBar?

    static let column: CGFloat = 250
    static let keyTimes = [0.15, 0.3, 0.45, 0.6, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(text: "ClipShot menu bar symbol - six proposals", size: 20, weight: .semibold)
            Caption(text: "Each a template glyph in the 22 x 16 pt status item, drawn as vector paths. Zoomed rows are 2x pixels enlarged. "
                + "Per concept folders hold states, menu bar renders (light, dark, tinted, highlighted, 1x, 2x), the app icon pairing, "
                + "the copy animation as a frame strip, MP4 and GIF.", size: 11)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                Spacer().frame(width: 96)
                ForEach(SymbolConcept.allCases) { concept in
                    VStack(alignment: .leading, spacing: 3) {
                        Caption(text: "\(concept.rawValue)  \(concept.name)", size: 15, weight: .semibold)
                        Caption(text: concept.pitch, size: 10).foregroundStyle(.secondary)
                    }
                    .frame(width: Self.column - 14, alignment: .topLeading)
                    .padding(.horizontal, 7)
                }
            }
            row("idle, zoomed", BarStyle.light) { concept, style in
                Px(image: SymbolConceptSheets.glyph(concept, .still(.idle), style.ink, scale: 2), zoom: 5)
            }
            row("idle, zoomed", BarStyle.dark) { concept, style in
                Px(image: SymbolConceptSheets.glyph(concept, .still(.idle), style.ink, scale: 2), zoom: 5)
            }
            ForEach([BarStyle.light, BarStyle.dark]) { style in
                row("states 2x zoomed: idle, copied, paused, attention", style) { concept, style in
                    HStack(spacing: 6) {
                        ForEach(SymbolConceptSheets.stills, id: \.0) { _, state in
                            Px(image: SymbolConceptSheets.glyph(concept, .still(state), style.ink, scale: 2), zoom: 2)
                        }
                    }
                }
            }
            row("actual size: 2x, then 1x", BarStyle.tinted) { concept, style in
                VStack(spacing: 6) {
                    BarStrip(style: style, concept: concept, frames: SymbolConceptSheets.stills.map { .still($0.1) }, scale: 2,
                             siblings: false)
                    BarStrip(style: style, concept: concept, frames: SymbolConceptSheets.stills.map { .still($0.1) }, scale: 1,
                             siblings: false)
                }
            }
            if let bar {
                row("in your menu bar, actual size", nil) { concept, _ in
                    VStack(spacing: 4) {
                        Px(image: bar.image(concept, .still(.idle), highlighted: false))
                        Px(image: bar.image(concept, .still(.idle), highlighted: true))
                    }
                }
            }
            row("copy keyframes (0.15, 0.3, 0.45, 0.6, 0.9 s)", BarStyle.dark) { concept, style in
                HStack(spacing: 2) {
                    ForEach(Self.keyTimes, id: \.self) { t in
                        Px(image: SymbolConceptSheets.glyph(concept, .copy(t), style.ink, scale: 2), zoom: 2)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 96 + Self.column * CGFloat(SymbolConcept.allCases.count) + 36, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func row<Cell: View>(_ label: String, _ style: BarStyle?,
                                 @ViewBuilder cell: @escaping (SymbolConcept, BarStyle) -> Cell) -> some View {
        HStack(spacing: 0) {
            Caption(text: label, size: 10, weight: .semibold)
                .foregroundStyle(style?.ink ?? .black)
                .frame(width: 88, alignment: .leading)
                .padding(.leading, 8)
            ForEach(SymbolConcept.allCases) { concept in
                cell(concept, style ?? .light)
                    .frame(width: Self.column, height: nil)
            }
        }
        .padding(.vertical, 10)
        .background(style?.background ?? AnyShapeStyle(Color(white: 0.97)))
    }
}
#endif
