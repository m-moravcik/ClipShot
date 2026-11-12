import AppKit
import Testing
import UniformTypeIdentifiers
@testable import ClipShot

@MainActor
struct MarkupOpenerTests {
    /// macOS 26 may lack `com.apple.MarkupUI.Markup` (verified on 27 only): Preview.app opens it.
    @Test func missingExtensionFallsBackToPreview() throws {
        let url = try Fixtures.write(named: "Screenshot.png", in: try Fixtures.makeDir())
        var asked: [String] = []
        var opened: [URL] = []
        let opener = MarkupOpener(
            makeService: { asked.append($0); return nil },
            openPreview: { opened.append($0); return true })
        var results: [MarkupResult] = []
        opener.open(url) { results.append($0) }
        #expect(asked == [MarkupOpener.extensionIdentifier])
        #expect(opened == [url])
        #expect(results == [.openedInPreview])
    }

    /// Minor 5: Done with an edited copy. The copy is opened before the delegate returns (the
    /// extension may clean it up at once) and read off the main actor, so the result comes
    /// later, and still holds the bytes once the path is gone.
    @Test func aReturnedCopyIsReadOffTheMainActorEvenWhenItsPathGoes() async throws {
        let dir = try Fixtures.makeDir()
        let original = try Fixtures.write(named: "Screenshot.png", in: dir)
        let edited = Fixtures.pngImage(size: 31)
        let copy = try Fixtures.write(named: "Edited.png", contents: edited, in: try Fixtures.makeDir())
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        let results = Results()
        opener.beginForTesting(original) { results.all.append($0) }

        opener.returned([original, copy])
        #expect(results.all.isEmpty, "not read on the main actor, before the delegate returns")
        // The extension cleans up its temporary copy.
        try FileManager.default.moveItem(at: copy, to: dir.appendingPathComponent("elsewhere.png"))
        #expect(await eventually { await results.all == [.savedCopy(edited)] })
    }

    /// macOS 27: Done hands back an `NSItemProvider` with the edited PNG and leaves the file
    /// as it was. That image is the edit, not a Cancel.
    @Test func anItemProviderIsTheEditedImage() async throws {
        let original = try Fixtures.write(named: "Screenshot.png", in: try Fixtures.makeDir())
        let edited = Fixtures.pngImage(size: 31)
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        let results = Results()
        opener.beginForTesting(original) { results.all.append($0) }

        opener.returned([NSItemProvider(item: edited as NSData, typeIdentifier: UTType.png.identifier)])

        #expect(await eventually { await results.all == [.savedCopy(edited)] })
    }

    /// Markup hands the edit back in the file's own format (seen on macOS 27: a JPEG
    /// screenshot comes back as `public.jpeg`, HEIC as `public.heic`, TIFF as `public.tiff`).
    @Test(arguments: [UTType.jpeg, .heic, .tiff])
    func anItemProviderInTheFilesFormatIsTheEditedImage(_ type: UTType) async throws {
        let ext = type.preferredFilenameExtension ?? "img"
        let original = try Fixtures.write(
            named: "Screenshot.\(ext)", contents: Fixtures.image(type: type), in: try Fixtures.makeDir())
        let edited = Fixtures.image(type: type, size: 31)
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        let results = Results()
        opener.beginForTesting(original) { results.all.append($0) }

        opener.returned([NSItemProvider(item: edited as NSData, typeIdentifier: type.identifier)])

        #expect(await eventually { await results.all == [.savedCopy(edited)] })
    }

    @Test func anItemProviderWithoutAnImageIsClosed() throws {
        let original = try Fixtures.write(named: "Screenshot.png", in: try Fixtures.makeDir())
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        var results: [MarkupResult] = []
        opener.beginForTesting(original) { results.append($0) }
        opener.returned([NSItemProvider(item: "text" as NSString, typeIdentifier: UTType.plainText.identifier)])
        #expect(results == [.closed])
    }

    @Test func aReturnedCopyThatIsALinkIsNotRead() throws {
        let dir = try Fixtures.makeDir()
        let original = try Fixtures.write(named: "Screenshot.png", in: dir)
        let target = try Fixtures.write(named: "Target.png", in: try Fixtures.makeDir())
        let link = dir.appendingPathComponent("Edited.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        var results: [MarkupResult] = []
        opener.beginForTesting(original) { results.append($0) }
        opener.returned([link])
        #expect(results == [.closed])
    }

    @Test func noPreviewEitherFails() throws {
        let url = try Fixtures.write(named: "Screenshot.png", in: try Fixtures.makeDir())
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        var results: [MarkupResult] = []
        opener.open(url) { results.append($0) }
        #expect(results == [.failed])
    }
}

@MainActor
private final class Results {
    var all: [MarkupResult] = []
}
