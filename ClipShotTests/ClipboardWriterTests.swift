import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipShot

struct ClipboardWriterTests {
    private func tmp(_ name: String, _ data: Data) throws -> URL {
        let url = try Fixtures.makeDir().appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func pngPassesThroughByteIdentical() throws {
        let data = Fixtures.pngImage()
        let url = try tmp("a.png", data)
        #expect(PNGConverter.pngData(from: url) == data)
    }
    @Test func jpgConvertsToPNGSignature() throws {
        let url = try tmp("a.jpg", Fixtures.image(type: .jpeg))
        let out = try #require(PNGConverter.pngData(from: url))
        #expect(Array(out.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
    @Test func truncatedImageYieldsNil() throws {
        let full = Fixtures.pngImage(size: 64)
        #expect(PNGConverter.pngData(from: try tmp("a.png", full.prefix(full.count / 2))) == nil)
        let jpg = Fixtures.image(type: .jpeg, size: 64)
        #expect(PNGConverter.pngData(from: try tmp("b.jpg", jpg.prefix(jpg.count / 2))) == nil)
    }
    @Test func pdfFirstPageRendersAt2x() throws {
        let url = try Fixtures.makeDir().appendingPathComponent("a.pdf")
        var box = CGRect(x: 0, y: 0, width: 50, height: 30)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        let out = try #require(PNGConverter.pngData(from: url))
        let src = try #require(CGImageSourceCreateWithData(out as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 100 && img.height == 60)
    }
    @Test func convertsOffMainActor() async throws {
        let url = try tmp("a.jpg", Fixtures.image(type: .jpeg))
        let out = await Task.detached { PNGConverter.pngData(from: url) }.value
        #expect(out != nil)
    }

    @MainActor @Test func pasteboardHoldsOnlyPNGType() {
        let pb = NSPasteboard(name: NSPasteboard.Name("clipshot-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.setString("old", forType: .string)
        let data = Fixtures.pngImage()
        #expect(SystemPasteboard(pasteboard: pb).writePNG(data))
        let types = pb.types ?? []
        #expect(types.contains(.png))
        #expect(!types.contains(.string))
        #expect(!types.contains(.fileURL))
        #expect(!types.contains(.URL))
        #expect(pb.data(forType: .png) == data)
    }
}
