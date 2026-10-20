import AppKit
import Testing
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

    @Test func noPreviewEitherFails() throws {
        let url = try Fixtures.write(named: "Screenshot.png", in: try Fixtures.makeDir())
        let opener = MarkupOpener(makeService: { _ in nil }, openPreview: { _ in false })
        var results: [MarkupResult] = []
        opener.open(url) { results.append($0) }
        #expect(results == [.failed])
    }
}
