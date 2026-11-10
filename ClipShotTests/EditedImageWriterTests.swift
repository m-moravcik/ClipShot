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

        #expect(outcome(of: result) == .saved)
        #expect(try Data(contentsOf: url) == edited)
        let after = try #require(CaptureFile.inspect(url))
        #expect(after.isScreenshot, "the marker the ledger needs is kept")
        #expect(CaptureMarker.captureType(of: url) == "selection")
        #expect(after.created == created)
        #expect(after.modified > created)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Screenshot.png"])
    }

    /// Done without a change: macOS 27 still hands back the image, re-encoded (2.3 times the
    /// bytes, the same pixels). The file is left as it was, so nothing is copied.
    @Test func anEditWithTheSamePixelsLeavesTheFileAlone() throws {
        let dir = try Fixtures.makeDir()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Fixtures.pngImage(size: 30)
        let url = try Fixtures.write(named: "Screenshot.png", contents: original, in: dir, created: created, modified: created)
        let before = try #require(CaptureFile.inspect(url))
        let reencoded = Fixtures.image(type: .tiff, size: 30)
        #expect(reencoded != original)

        let result = EditedImageWriter.save(reencoded, over: url, expectedResourceID: before.resourceID)

        #expect(outcome(of: result) == .unchanged)
        #expect(try Data(contentsOf: url) == original)
        #expect(CaptureFile.inspect(url) == before, "same inode, same modification time")
    }

    /// One changed pixel is an edit.
    @Test func anEditOfOnePixelIsSaved() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.png", contents: Fixtures.pngImage(size: 30), in: dir)
        let before = try #require(CaptureFile.inspect(url))
        let edited = Fixtures.pngImage(size: 30, mark: CGPoint(x: 7, y: 11))

        let result = EditedImageWriter.save(edited, over: url, expectedResourceID: before.resourceID)

        #expect(outcome(of: result) == .saved)
        #expect(try Data(contentsOf: url) == edited)
    }

    /// Markup's Rotate only sets the orientation tag (8, rotated 90° left in EXIF/TIFF terms)
    /// and keeps the stored pixels: that is an edit, and the file then shows it rotated.
    @Test func aRotationThatOnlySetsTheOrientationIsSaved() throws {
        let dir = try Fixtures.makeDir()
        let original = Fixtures.image(type: .tiff, size: 30)
        let url = try Fixtures.write(named: "Screenshot.tiff", contents: original, in: dir)
        let before = try #require(CaptureFile.inspect(url))
        let rotated = try withOrientation(8, original)

        let result = EditedImageWriter.save(rotated, over: url, expectedResourceID: before.resourceID)

        #expect(outcome(of: result) == .saved)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == 8)
    }

    /// An image without an orientation tag shows the same as one tagged 1 (up), so Done
    /// without a change that only adds the default tag leaves the file alone.
    @Test func theDefaultOrientationTagIsNotAnEdit() throws {
        let dir = try Fixtures.makeDir()
        let original = Fixtures.pngImage(size: 30)
        let url = try Fixtures.write(named: "Screenshot.png", contents: original, in: dir)
        let before = try #require(CaptureFile.inspect(url))

        let result = EditedImageWriter.save(
            try withOrientation(1, Fixtures.image(type: .tiff, size: 30)), over: url, expectedResourceID: before.resourceID)

        #expect(outcome(of: result) == .unchanged)
        #expect(try Data(contentsOf: url) == original)
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

    /// `data` re-encoded in its own format with the pixels as they are and the orientation
    /// tag set, as Markup's Rotate hands it back.
    private func withOrientation(_ orientation: Int, _ data: Data) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try #require(CGImageSourceGetType(source))
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, type, 1, nil))
        CGImageDestinationAddImageFromSource(
            destination, source, 0, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func failure(of result: Result<EditedImageWriter.Outcome, EditedImageWriter.Failure>) -> EditedImageWriter.Failure? {
        if case .failure(let failure) = result { failure } else { nil }
    }

    private func outcome(of result: Result<EditedImageWriter.Outcome, EditedImageWriter.Failure>) -> EditedImageWriter.Outcome? {
        if case .success(let outcome) = result { outcome } else { nil }
    }
}
