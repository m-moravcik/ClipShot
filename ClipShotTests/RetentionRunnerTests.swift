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
}
