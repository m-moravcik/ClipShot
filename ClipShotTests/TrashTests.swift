import Foundation
import Testing
@testable import ClipShot

@MainActor
struct TrashTests {
    @Test func trashOnlyLedgerFilesInsideFolder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let old = Date().addingTimeInterval(-3_600)
        // Already there before ClipShot watched: never in the ledger.
        let untracked = try Fixtures.write(named: "Before.png", in: h.folder, created: old, modified: old)
        #expect(await h.start())

        await #expect(throws: AppModel.TrashError.notTracked) {
            try await h.model.trash(try #require(CaptureFile.inspect(untracked)))
        }

        // In the ledger, but not in the screenshot folder.
        let elsewhere = try Fixtures.makeDir()
        let outside = try #require(CaptureFile.inspect(try Fixtures.write(named: "Elsewhere.png", in: elsewhere)))
        await h.ledger.adopt([outside])
        await #expect(throws: AppModel.TrashError.outsideFolder) { try await h.model.trash(outside) }

        // A screenshot ClipShot saw being taken.
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        try await h.model.trash(file)
        #expect(!RT.exists(url))
        #expect(h.trasher.trashed == ["Screenshot 1.png"])
        #expect(await !h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID))
        #expect(RT.exists(untracked) && RT.exists(outside.url))
        #expect(h.preferences.totals.trashed == 1)
    }

    @Test func replacedFileIsNotTrashed() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        // Something else now has the name: a new inode.
        try Fixtures.write(named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 40), in: h.folder)
        await #expect(throws: AppModel.TrashError.self) { try await h.model.trash(file) }
        #expect(RT.exists(url))
        #expect(h.trasher.trashed.isEmpty)
    }

    @Test func undoTrashPutsFileBack() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        #expect(await h.model.undoTrash() == false, "nothing to undo")
        let data = Fixtures.pngImage(size: 24)
        let url = try Fixtures.write(named: "Screenshot 1.png", contents: data, in: h.folder)
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        try await h.model.trash(file)
        #expect(!RT.exists(url))

        #expect(await h.model.undoTrash())
        #expect(try Data(contentsOf: url) == data)
        let restored = try #require(CaptureFile.inspect(url))
        #expect(restored.isScreenshot)
        #expect(await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: restored.resourceID))
        #expect(h.preferences.totals.trashed == 0)
        #expect(await h.model.undoTrash() == false, "undo once")
    }
}
