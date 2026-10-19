import Foundation
import Testing
@testable import ClipShot

struct RetentionRunnerTests {
    private func setUp(_ names: [String]) async throws -> (dir: URL, ledger: ScreenshotLedger, scan: RetentionScan, now: Date) {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let ledger = try RT.ledger()
        for name in names {
            await ledger.record(RT.file(try RT.shot(name, in: dir, age: 40 * RT.day, now: now)))
        }
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: await ledger.entries(), now: now).success)
        #expect(scan.expired.count == names.count)
        return (dir, ledger, scan, now)
    }

    @Test func runnerTrashesAndReportsFailures() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png", "b.jpg", "c.png"])
        let trasher = try FakeTrasher(failing: ["b.jpg"])
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 2)
        #expect(result.failed == 1)
        #expect(result.movedBytes == Int64(2 * RT.png.count))
        #expect(result.at == now)
        #expect(Set(trasher.trashed) == ["a.png", "c.png"])
        #expect(RT.exists(dir.appendingPathComponent("b.jpg")))
        // Moved entries leave the ledger; the failed one stays for the next run.
        #expect(await ledger.entries().map { ($0.path as NSString).lastPathComponent } == ["b.jpg"])
    }

    @Test func runnerSkipsFileReplacedAfterScan() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png"])
        // Same name, new inode, also marked and old: still not the file ClipShot saw.
        try RT.shot("a.png", in: dir, age: 40 * RT.day, now: now)
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 0)
        #expect(result.failed == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(dir.appendingPathComponent("a.png")))
    }

    @Test func runnerSkipsFileWhoseMarkerWasRemoved() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png"])
        let url = dir.appendingPathComponent("a.png")
        #expect(removexattr(url.path, CaptureMarker.captureFlag, XATTR_NOFOLLOW) == 0)
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(url))
    }

    @Test func runnerSkipsEntryRemovedFromLedgerAfterScan() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png"])
        let url = dir.appendingPathComponent("a.png")
        // Renamed away and back: the ledger dropped the entry, the scan is stale.
        let other = dir.appendingPathComponent("b.png")
        #expect(rename(url.path, other.path) == 0)
        await ledger.prune()
        #expect(rename(other.path, url.path) == 0)
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 0)
        #expect(RT.exists(url))
    }

    @Test func runnerSkipsWhenFolderBecameASymlink() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png"])
        // The folder is swapped for a symlink to a folder holding the very same file (same inode).
        let parked = try Fixtures.makeDir().appendingPathComponent("parked")
        #expect(rename(dir.path, parked.path) == 0)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: parked)
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 0)
        #expect(RT.exists(parked.appendingPathComponent("a.png")))
    }

    @Test func runnerSkipsFileThatIsNoLongerExpired() async throws {
        let (_, ledger, scan, now) = try await setUp(["a.png"])
        let trasher = try FakeTrasher()
        // Clock moved back past the expiry boundary.
        let result = try await RT.runner(trasher, ledger).run(scan, now: now.addingTimeInterval(-20 * RT.day))
        #expect(result.moved == 0)
        #expect(trasher.trashed.isEmpty)
    }

    // MARK: - Forged scans: the runner re-checks what the scanner promised.

    private func forged(folder: URL, expired: [CaptureFile], days: Int = 30) -> RetentionScan {
        RetentionScan(
            folder: folder, days: days, expired: expired,
            expiredBytes: expired.reduce(0) { $0 + $1.size },
            skippedUnmarkedImages: 0, olderNotTracked: 0, olderNotTrackedBytes: 0, pending: 0)
    }

    @Test func runnerSkipsForgedScanOfBroadFolder() async throws {
        let (dir, ledger, scan, now) = try await setUp(["a.png"])
        let file = try #require(scan.expired.first)
        // The scan folder is an ancestor of the home folder the runner is given, so it is broad.
        let home = scan.folder.appendingPathComponent("me", isDirectory: true)
        let trasher = try FakeTrasher()
        let runner = RetentionRunner(trasher: trasher, ledger: ledger, home: home, log: try RT.testLog())
        let result = await runner.run(forged(folder: scan.folder, expired: [file]), now: now)
        #expect(result.moved == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(dir.appendingPathComponent("a.png")))
        // The home folder itself is broad too.
        let atHome = RetentionRunner(trasher: trasher, ledger: ledger, home: scan.folder, log: try RT.testLog())
        #expect(await atHome.run(forged(folder: scan.folder, expired: [file]), now: now).moved == 0)
        #expect(trasher.trashed.isEmpty)
        // Control: the same scan with an unrelated home is moved.
        #expect(try await RT.runner(trasher, ledger).run(scan, now: now).moved == 1)
    }

    @Test func runnerSkipsForgedFileThatIsNotADirectChild() async throws {
        let (_, ledger, scan, now) = try await setUp([])
        let sub = scan.folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = RT.file(try RT.shot("a.png", in: sub, age: 40 * RT.day, now: now))
        await ledger.record(nested)
        #expect(await ledger.contains(path: nested.url.path, resourceID: nested.resourceID))
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(forged(folder: scan.folder, expired: [nested]), now: now)
        #expect(result.moved == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(nested.url))
    }

    @Test func runnerSkipsForgedDotDotSpellings() async throws {
        let (_, ledger, scan, now) = try await setUp(["a.png"])
        let real = try #require(scan.expired.first)
        let sub = scan.folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // The same file reached through "sub/..": same inode, non-canonical spelling.
        let dotted = try #require(CaptureFile.inspect(URL(fileURLWithPath: sub.path + "/../a.png")))
        #expect(dotted.resourceID == real.resourceID)
        // The folder itself spelled with "..".
        let dottedFolder = URL(fileURLWithPath: sub.path + "/..", isDirectory: true)
        let trasher = try FakeTrasher()
        let runner = try RT.runner(trasher, ledger)
        #expect(await runner.run(forged(folder: scan.folder, expired: [dotted]), now: now).moved == 0)
        #expect(await runner.run(forged(folder: dottedFolder, expired: [real]), now: now).moved == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(real.url))
        // The re-check itself rejects both, not only the ledger lookup.
        #expect(RetentionRunner.revalidate(dotted, in: forged(folder: scan.folder, expired: []), now: now, home: RT.home) == nil)
        #expect(RetentionRunner.revalidate(real, in: forged(folder: dottedFolder, expired: []), now: now, home: RT.home) == nil)
        #expect(RetentionRunner.revalidate(real, in: scan, now: now, home: RT.home) != nil)
    }
}
