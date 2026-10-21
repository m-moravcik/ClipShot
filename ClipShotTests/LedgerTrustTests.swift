import Foundation
import Testing
@testable import ClipShot

/// The ledger is a file of the user's that any process of theirs can write (final review 2,
/// N-1): an entry alone never makes a file listable or copyable, the marker on the file
/// itself does. The ledger is read as untrusted, and a copy reads the file that was chosen
/// (N-2).
@MainActor
struct LedgerTrustTests {
    /// A ledger written by hand, as another process could, before ClipShot reads it.
    private func forge(_ urls: [URL], into ledger: URL, extra: [[String: Any]] = [], version: Int = 1) throws {
        var entries: [[String: Any]] = try urls.map { url in
            let file = try #require(CaptureFile.stat(url))
            return [
                "path": FolderGuard.canonicalPath(url), "resourceID": file.resourceID.base64EncodedString(),
                "created": file.created.timeIntervalSince1970, "size": file.size,
            ]
        }
        entries += extra
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "entries": entries])
        try data.write(to: ledger)
    }

    /// The reviewer's probe: an unmarked download listed in a hand-written ledger is refused
    /// on every path: copy PATH, copy, latest (with and without the app), Get Latest, Copy
    /// Latest and the popover's list.
    @Test func anUnmarkedFileInAForgedLedgerIsRefusedEverywhere() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let download = try RT.shot("download.png", in: h.folder, age: 60, now: RT.now(), marker: .none, quarantine: true)
        try forge([download], into: h.ledgerURL)
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)

        let copyPath = await tool.run(["copy", download.path])
        #expect(copyPath.exit == .error && copyPath.stderr.contains("is not a screenshot ClipShot saw being taken"))
        #expect(await tool.run(["copy"]).stderr == "error: \(Copy.Shortcuts.noScreenshots.key)\n")
        #expect(await tool.run(["latest"]).exit == .error)
        let offline = h.tool(try CT.shortDir())
        #expect(await offline.run(["latest"]).stderr == "error: \(Copy.Shortcuts.noScreenshots.key)\n")
        await #expect(throws: ShortcutError.noScreenshots) { try await h.model.shortcutScreenshots(count: 1) }
        await #expect(throws: ShortcutError.noScreenshots) { try await h.model.shortcutCopyLatest() }
        h.model.refreshRecent()
        #expect(await eventually { await h.model.recentSettled })
        #expect(h.model.recent.isEmpty)
        #expect(h.pasteboard.writes.isEmpty && h.preferences.totals.copied == 0)
    }

    /// A marked screenshot in the same forged ledger is listed: the marker is what counts.
    @Test func aMarkedScreenshotInTheLedgerIsStillListed() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let shot = try RT.shot("shot.png", in: h.folder, age: 60, now: RT.now())
        let plain = try RT.shot("plain.png", in: h.folder, age: 30, now: RT.now(), marker: .none)
        try forge([shot, plain], into: h.ledgerURL)
        #expect(await h.start())
        #expect(try await h.model.shortcutScreenshots(count: 10).files.map(\.name) == ["shot.png"])
    }

    // MARK: Reading the ledger

    @Test func malformedEntriesAreDroppedAndLogged() async throws {
        let dir = try Fixtures.makeDir()
        let shot = try RT.shot("shot.png", in: dir, age: 60, now: RT.now())
        let ledgerURL = dir.appendingPathComponent("ledger.json")
        let good = try #require(CaptureFile.stat(shot))
        let id = good.resourceID.base64EncodedString()
        try forge([shot], into: ledgerURL, extra: [
            ["path": "relative.png", "resourceID": id, "created": 1, "size": 1],
            ["path": "/a/../etc/passwd", "resourceID": id, "created": 1, "size": 1],
            ["path": "/a/b.png", "resourceID": Data([1, 2]).base64EncodedString(), "created": 1, "size": 1],
            ["path": "/a/c.png", "resourceID": id, "created": 1, "size": -5],
            ["path": "/a/d.png"],
            ["nonsense": true],
        ])
        let logURL = dir.appendingPathComponent("test.log")
        let ledger = ScreenshotLedger(fileURL: ledgerURL, log: Log(fileURL: logURL))
        #expect(await ledger.entries().map(\.path) == [FolderGuard.canonicalPath(shot)])
        #expect(await eventually {
            ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").contains("ledger: dropped 6 malformed entries")
        })
    }

    @Test func aLedgerOfAnotherShapeOrKindIsNotRead() throws {
        let dir = try Fixtures.makeDir()
        let shot = try RT.shot("shot.png", in: dir, age: 60, now: RT.now())
        let ledger = dir.appendingPathComponent("ledger.json")

        try forge([shot], into: ledger, version: 2)
        #expect(ScreenshotLedger.read(ledger).entries.isEmpty)
        #expect(ScreenshotLedger.read(ledger).problem == "unknown version 2, starting empty")

        try Data("not json".utf8).write(to: ledger)
        #expect(ScreenshotLedger.read(ledger).problem == "unreadable, starting empty")

        // A symlink to a ledger elsewhere is not followed.
        let real = dir.appendingPathComponent("real.json")
        try forge([shot], into: real)
        #expect(ScreenshotLedger.read(real).entries.count == 1)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ScreenshotLedger.read(link).entries.isEmpty)
        #expect(ScreenshotLedger.read(link).problem == "refused (not a regular file), starting empty")

        // Larger than any ledger ClipShot writes: refused unread (sparse, no disk used).
        let huge = dir.appendingPathComponent("huge.json")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(ScreenshotLedger.maxBytes) + 1)
        try handle.close()
        #expect(ScreenshotLedger.read(huge).problem == "refused (file too large), starting empty")

        // Missing: simply empty, nothing to say.
        let missing = ScreenshotLedger.read(dir.appendingPathComponent("none.json"))
        #expect(missing.entries.isEmpty && missing.problem == nil)
    }

    // MARK: The bytes copied are the file chosen

    @Test func fileTrustRefusesAnotherFileAtThePath() throws {
        let dir = try Fixtures.makeDir()
        let url = try RT.shot("shot.png", in: dir, age: 60, now: RT.now())
        let chosen = try #require(CaptureFile.inspect(url))
        #expect(FileTrust.open(url, policy: FileTrust.Policy(expectedResourceID: chosen.resourceID)).success != nil)
        // Replaced by rename: same path, another inode.
        let other = try RT.shot("other.png", in: dir, age: 60, now: RT.now())
        #expect(rename(other.path, url.path) == 0)
        guard case .failure(.replaced) = FileTrust.open(url, policy: FileTrust.Policy(expectedResourceID: chosen.resourceID)) else {
            Issue.record("another file at the path was opened")
            return
        }
        #expect(PNGConverter.convert(url, policy: FileTrust.Policy(expectedResourceID: chosen.resourceID)) == .refused(.replaced))
    }

    /// A tracked file swapped at its path after it was chosen: the copy reads nothing of the
    /// newcomer and says it failed.
    @Test func aCopyOfAFileReplacedSinceItWasChosenFails() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let url = try RT.shot("shot.png", in: h.folder, age: 60, now: RT.now())
        await h.ledger.record(RT.file(url))
        #expect(await h.start())
        let chosen = try #require(CaptureFile.inspect(url))
        let swapped = try RT.shot("swap.png", in: h.home, age: 60, now: RT.now())
        #expect(rename(swapped.path, url.path) == 0)
        #expect(await h.model.copyExplicitly(chosen) == false)
        #expect(h.pasteboard.writes.isEmpty)
    }
}
