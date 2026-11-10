import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipShot

/// The edit Markup hands back is saved over the screenshot (spec Addendum A4).
struct EditedImageWriterTests {
    /// The file holds the edit, and is still the same screenshot: its marker and creation
    /// date carry over, only its content and modification time change.
    @Test func theEditReplacesTheFileAndKeepsItAScreenshot() throws {
        let dir = try Fixtures.makeDir()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try Fixtures.write(
            named: "Screenshot.png", contents: Fixtures.pngImage(size: 30), in: dir,
            created: created, modified: created)
        let before = try #require(CaptureFile.inspect(url))
        let edited = Fixtures.pngImage(size: 31)

        let result = EditedImageWriter.save(edited, over: url, expectedResourceID: before.resourceID)

        #expect(failure(of: result) == nil)
        #expect(try Data(contentsOf: url) == edited)
        let after = try #require(CaptureFile.inspect(url))
        #expect(after.isScreenshot, "the marker the ledger needs is kept")
        #expect(CaptureMarker.captureType(of: url) == "selection")
        #expect(after.created == created)
        #expect(after.modified > created)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Screenshot.png"])
    }

    /// A file put at the path while the editor was open is not overwritten.
    @Test func aFileReplacedDuringTheEditIsLeftAlone() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.png", in: dir)
        let opened = try #require(CaptureFile.inspect(url))
        let other = Fixtures.pngImage(size: 20)
        try Fixtures.write(named: "Screenshot.png", contents: other, in: dir)

        let result = EditedImageWriter.save(Fixtures.pngImage(size: 31), over: url, expectedResourceID: opened.resourceID)

        #expect(failure(of: result) == .notTheOriginal)
        #expect(try Data(contentsOf: url) == other)
    }

    /// Screenshots saved as JPEG stay JPEG: the PNG Markup hands back is re-encoded.
    @Test func theEditTakesTheFormatOfTheFile() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.jpg", contents: Fixtures.image(type: .jpeg), in: dir)
        let file = try #require(CaptureFile.inspect(url))

        let result = EditedImageWriter.save(Fixtures.pngImage(size: 31), over: url, expectedResourceID: file.resourceID)

        #expect(failure(of: result) == nil)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 31)
    }

    @Test func aPDFCaptureIsNotWritten() throws {
        let dir = try Fixtures.makeDir()
        let original = Data("%PDF-1.4\n".utf8)
        let url = try Fixtures.write(named: "Screenshot.pdf", contents: original, in: dir)
        let file = try #require(CaptureFile.inspect(url))

        let result = EditedImageWriter.save(Fixtures.pngImage(), over: url, expectedResourceID: file.resourceID)

        #expect(failure(of: result) == .unsupportedFormat)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func dataThatIsNotAnImageIsNotWritten() throws {
        let dir = try Fixtures.makeDir()
        let original = Fixtures.pngImage()
        let url = try Fixtures.write(named: "Screenshot.png", contents: original, in: dir)
        let file = try #require(CaptureFile.inspect(url))

        let result = EditedImageWriter.save(Data("not an image".utf8), over: url, expectedResourceID: file.resourceID)

        #expect(failure(of: result) == .undecodable)
        #expect(try Data(contentsOf: url) == original)
    }

    private func failure(of result: Result<Void, EditedImageWriter.Failure>) -> EditedImageWriter.Failure? {
        if case .failure(let failure) = result { failure } else { nil }
    }
}
