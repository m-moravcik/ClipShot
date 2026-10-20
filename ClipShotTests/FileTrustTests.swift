import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// S3: a file is read only when this user owns it, through no symlink, within the size and
/// pixel limits; anything else is refused quietly.
struct FileTrustTests {
    private static let otherUser = getuid() + 1

    private func shot(_ name: String = "Screenshot.png", size: Int = 16) throws -> URL {
        try Fixtures.write(named: name, contents: Fixtures.pngImage(size: size), in: try Fixtures.makeDir())
    }

    @Test func readsAFileThisUserOwns() throws {
        let url = try shot()
        #expect(try FileTrust.read(url).get() == Data(contentsOf: url))
        #expect(PNGConverter.convert(url) == .png(try Data(contentsOf: url)))
    }

    /// Opened and checked now, read later: what was checked is what is read, also after the
    /// path went away (Markup's temporary copy).
    @Test func anOpenedFileIsReadAfterItsPathIsGone() throws {
        let url = try shot()
        let bytes = try Data(contentsOf: url)
        let opened = try FileTrust.open(url).get()
        try FileManager.default.moveItem(at: url, to: try Fixtures.makeDir().appendingPathComponent("moved.png"))
        #expect(try opened.read().get() == bytes)
        let refused: FileTrust.Refusal? = switch FileTrust.open(try shot(), policy: FileTrust.Policy(owner: Self.otherUser)) {
        case .success: nil
        case .failure(let refusal): refusal
        }
        #expect(refused == .notOwned, "opening checks as reading does")
    }

    @Test func refusesAnotherUsersFile() throws {
        let url = try shot()
        let policy = FileTrust.Policy(owner: Self.otherUser)
        #expect(FileTrust.read(url, policy: policy) == .failure(.notOwned))
        #expect(PNGConverter.convert(url, policy: policy) == .refused(.notOwned))
        #expect(Thumbnailer.decode(url, maxPixelSize: 64, policy: policy) == nil)
        // Not a screenshot, and its attributes are never even read.
        #expect(CaptureFile.inspect(url, owner: Self.otherUser)?.isScreenshot == false)
        let read = Mutex(0)
        let file = try #require(CaptureFile.stat(url, owner: Self.otherUser))
        #expect(!file.isOwnedByUser)
        #expect(!file.readingMarker { _ in read.withLock { $0 += 1 }; return true }.isScreenshot)
        #expect(read.withLock { $0 } == 0)
    }

    @Test func refusesASymlink() throws {
        let target = try shot()
        let link = try Fixtures.makeDir().appendingPathComponent("Screenshot link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(FileTrust.read(link) == .failure(.notRegular))
        #expect(PNGConverter.convert(link) == .refused(.notRegular))
        #expect(Thumbnailer.decode(link, maxPixelSize: 64) == nil)
        #expect(CaptureFile.inspect(link) == nil)
    }

    @Test func refusesAFileOverTheSizeLimit() throws {
        let url = try shot()
        let policy = FileTrust.Policy(maxBytes: 10)
        #expect(FileTrust.read(url, policy: policy) == .failure(.tooLarge))
        #expect(PNGConverter.convert(url, policy: policy) == .refused(.tooLarge))
    }

    /// A file that grows after `fstat` is never read whole: the read stops one byte past
    /// the limit.
    @Test func theReadIsBoundedByTheSizeLimit() throws {
        let url = try Fixtures.makeDir().appendingPathComponent("Growing.png")
        try Data(repeating: 7, count: 100_000).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(FileTrust.readBounded(handle, maxBytes: 10) == .failure(.tooLarge))
        #expect(try handle.offset() == 11)

        let exact = try FileHandle(forReadingFrom: url)
        defer { try? exact.close() }
        #expect(try FileTrust.readBounded(exact, maxBytes: 100_000).get().count == 100_000)
    }

    @Test func refusesAnImageOverThePixelLimit() throws {
        let url = try shot(size: 16)
        let policy = FileTrust.Policy(maxPixels: 16 * 16 - 1)
        #expect(PNGConverter.convert(url, policy: policy) == .refused(.tooManyPixels))
        #expect(Thumbnailer.decode(url, maxPixelSize: 8, policy: policy) == nil)
        #expect(PNGConverter.pngData(fromImageData: try Data(contentsOf: url), policy: policy) == nil)
        #expect(PNGConverter.convert(url, policy: FileTrust.Policy(maxPixels: 16 * 16)) != .refused(.tooManyPixels))
        // Width times height that overflows is never allowed.
        #expect(!FileTrust.allowsPixels(width: .max, height: 2, policy: .standard))
    }

    @Test func refusesAPDFPageThatWouldRasterTooLarge() throws {
        let url = try Fixtures.makeDir().appendingPathComponent("Screenshot.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 50)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
        // Rastered at 2x: 200 x 100 pixels.
        #expect(PNGConverter.convert(url, policy: FileTrust.Policy(maxPixels: 200 * 100 - 1)) == .refused(.tooManyPixels))
        guard case .png(let png) = PNGConverter.convert(url, policy: FileTrust.Policy(maxPixels: 200 * 100)) else {
            Issue.record("the PDF within the limit was not converted")
            return
        }
        #expect(!png.isEmpty)
    }

    @Test func refusesAFolderOrAMissingFile() throws {
        let dir = try Fixtures.makeDir()
        let folder = dir.appendingPathComponent("Folder.png", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(FileTrust.read(folder) == .failure(.notRegular))
        #expect(FileTrust.read(dir.appendingPathComponent("gone.png")) == .failure(.unreadable))
    }
}
