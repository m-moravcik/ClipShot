import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a capture file to PNG data. Pure and nonisolated: safe off the main actor.
///
/// Every file is read through `FileTrust` first: owned by this user, no symlink, within the
/// size and pixel limits, and decoded from the bytes that were checked.
enum PNGConverter {
    enum Outcome: Equatable, Sendable {
        case png(Data)
        /// `FileTrust` refused the file: not an error to report, nothing to retry.
        case refused(FileTrust.Refusal)
        /// Not decodable (yet): a file still being written, or not an image.
        case failed
    }

    static func convert(_ url: URL, policy: FileTrust.Policy = .standard) -> Outcome {
        let data: Data
        switch FileTrust.read(url, policy: policy) {
        case .success(let read): data = read
        case .failure(let refusal): return .refused(refusal)
        }
        if url.pathExtension.lowercased() == "pdf" { return pdfFirstPage(data, policy: policy) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0
        else { return .failed }
        guard FileTrust.allowsPixels(of: source, policy: policy) else { return .refused(.tooManyPixels) }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString {
            // ImageIO reports truncated PNGs as complete, so check for the IEND trailer ourselves.
            return data.suffix(iend.count) == iend ? .png(data) : .failed
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = encode(image),
              // Status is only meaningful after the pixels have been decoded by the encode above.
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { return .failed }
        return .png(png)
    }

    static func pngData(from url: URL) -> Data? {
        if case .png(let data) = convert(url) { data } else { nil }
    }

    /// Image data in any format ImageIO reads (an edited copy Markup handed back), as PNG,
    /// within the same size and pixel limits.
    static func pngData(fromImageData data: Data, policy: FileTrust.Policy = .standard) -> Data? {
        guard Int64(data.count) <= policy.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              FileTrust.allowsPixels(of: source, policy: policy)
        else { return nil }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString, data.suffix(iend.count) == iend {
            return data
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image)
    }

    private static let iend = Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

    /// The first page at twice its size, as the screenshot looked on a Retina display;
    /// refused when that raster would pass the pixel limit.
    private static func pdfFirstPage(_ data: Data, policy: FileTrust.Policy) -> Outcome {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider), let page = doc.page(at: 1)
        else { return .failed }
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let w = (box.width * scale).rounded(.up), h = (box.height * scale).rounded(.up)
        guard w.isFinite, h.isFinite, w > 0, h > 0, w < 1_000_000, h < 1_000_000 else { return .failed }
        let width = Int(w), height = Int(h)
        guard FileTrust.allowsPixels(width: width, height: height, policy: policy) else { return .refused(.tooManyPixels) }
        guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .failed }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage(), let png = encode(image) else { return .failed }
        return .png(png)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
