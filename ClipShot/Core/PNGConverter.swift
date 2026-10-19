import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a capture file to PNG data. Pure and nonisolated: safe off the main actor.
enum PNGConverter {
    static func pngData(from url: URL) -> Data? {
        if url.pathExtension.lowercased() == "pdf" { return pdfFirstPage(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0
        else { return nil }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString {
            // ImageIO reports truncated PNGs as complete, so check for the IEND trailer ourselves.
            guard let data = try? Data(contentsOf: url), data.suffix(iend.count) == iend else { return nil }
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encode(image),
              // Status is only meaningful after the pixels have been decoded by the encode above.
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return nil }
        return png
    }

    private static let iend = Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

    private static func pdfFirstPage(_ url: URL) -> Data? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { return nil }
        return encode(image)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
