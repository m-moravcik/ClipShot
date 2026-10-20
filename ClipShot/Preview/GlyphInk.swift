#if DEBUG
import SwiftUI

/// Measures menu bar glyphs the way the eye sees them: the menu bar's scale-down of a tall
/// label, and the box of the pixels that are more than faintly drawn. Shared by the
/// screenshot harness's menu bar sheets and the status icon tests, so both measure alike.
@MainActor
enum GlyphInk {
    /// The pictures are 2x, as on a Retina menu bar.
    nonisolated static let scale: CGFloat = 2
    /// Alpha above which a pixel counts as ink: anti-aliased fringes stay out of the box.
    nonisolated static let alphaThreshold: UInt8 = 40

    /// `view` at 2x, as drawn, with no menu bar fitting.
    static func image(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// `view` at 2x, fitted into the menu bar's height as AppKit fits a MenuBarExtra label
    /// that is taller than `StatusIconArt.menuBarHeight`: scaled down proportionally.
    static func menuBarImage(_ view: some View) -> CGImage? {
        guard let image = image(view) else { return nil }
        let limit = Int(StatusIconArt.menuBarHeight * scale)
        guard image.height > limit else { return image }
        let width = Int((CGFloat(image.width) * CGFloat(limit) / CGFloat(image.height)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: limit, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: limit))
        return context.makeImage()
    }

    /// The point size of Eject Guard's menu bar symbol, the sibling ClipShot's icon is sized
    /// against.
    static let ejectGuardPointSize: CGFloat = 15

    /// Eject Guard's menu bar label: the `externaldrive` symbol at its point size.
    static func ejectGuardLabel() -> some View {
        Image(systemName: "externaldrive").font(.system(size: ejectGuardPointSize))
    }

    /// VibeRes's menu bar label: a plain symbol at the menu bar's own size.
    static func vibeResLabel() -> some View {
        Image(systemName: "rectangle.on.rectangle.angled")
    }

    /// `pose` drawn at 2x with `pad` points of room on every side, so nothing the canvas
    /// would clip is lost: its ink box is the whole drawing's.
    nonisolated static func unclipped(_ pose: Peg.Pose, pad: CGFloat) -> CGImage? {
        let width = Int((Peg.canvas.width + 2 * pad) * scale), height = Int((Peg.canvas.height + 2 * pad) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: pad, y: pad)
        Peg.draw(pose, in: context)
        return context.makeImage()
    }

    /// The idle card alone, without the line and the peg, drawn like `unclipped`: the shape
    /// that carries the glyph's weight, measured against the siblings' main shapes.
    nonisolated static func cardBody(pad: CGFloat) -> CGImage? {
        let width = Int((Peg.canvas.width + 2 * pad) * scale), height = Int((Peg.canvas.height + 2 * pad) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: pad, y: pad)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        Peg.drawCard(Peg.Card(), in: context)
        return context.makeImage()
    }

    /// The thickness in pixels of the first stroke met from the left, on the row at
    /// `fraction` of the ink box's height (counting pixels more than half covered).
    nonisolated static func leftStroke(_ image: CGImage, atHeight fraction: Double) -> Int {
        let width = image.width, height = image.height
        let pixels = alpha(image)
        var minY = height, maxY = -1
        for y in 0..<height where (0..<width).contains(where: { pixels[y * width + $0] > alphaThreshold }) {
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxY >= 0 else { return 0 }
        let y = minY + Int(Double(maxY - minY) * fraction)
        var run = 0
        for x in 0..<width {
            if pixels[y * width + x] > 127 { run += 1 } else if run > 0 { break }
        }
        return run
    }

    /// Every pixel's coverage, row by row from the top.
    nonisolated static func alpha(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// Which pixels of column `x` are more than half covered, over `rows` (from the top).
    nonisolated static func column(_ image: CGImage, x: Int, rows: ClosedRange<Int>) -> [Bool] {
        let pixels = alpha(image)
        return rows.map { pixels[$0 * image.width + x] > 127 }
    }

    /// Where the drawn pixels are, in pixels from the top leading corner; nil when nothing is
    /// drawn.
    nonisolated static func inkBox(_ image: CGImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let width = image.width
        let pixels = alpha(image)
        var minX = width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<width where pixels[y * width + x] > alphaThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    /// The bounding box of the drawn pixels, in pixels; (0, 0) for an empty image.
    nonisolated static func size(_ image: CGImage) -> (width: Int, height: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > alphaThreshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1)
    }
}
#endif
