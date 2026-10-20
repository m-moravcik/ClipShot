#if DEBUG
import SwiftUI

/// Measures menu bar glyphs the way the eye sees them: the menu bar's scale-down of a tall
/// label, and the box of the pixels that are more than faintly drawn. Shared by the
/// screenshot harness's menu bar sheets and the status icon tests, so both measure alike.
@MainActor
enum GlyphInk {
    /// The pictures are 2x, as on a Retina menu bar.
    static let scale: CGFloat = 2
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
