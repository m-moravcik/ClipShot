import Foundation
import Testing
@testable import ClipShot

struct RetentionScannerTests {
    @Test func unknownFilesAreNeverMoved() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 40 * RT.day, now: now)
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: [], now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.olderNotTracked == 1)
        #expect(scan.olderNotTrackedBytes == RT.file(a).size)
        #expect(scan.pending == 0)

        // A forged scan naming a file that is not in the ledger is still refused by the runner.
        let canonical = RT.file(scan.folder.appendingPathComponent("a.png"))
        let forged = RetentionScan(
            folder: scan.folder, days: 30, expired: [canonical], expiredBytes: 0,
            skippedUnmarkedImages: 0, olderNotTrackedFiles: [], pending: 0)
        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, try RT.ledger()).run(forged, now: now)
        #expect(result.moved == 0)
        #expect(trasher.trashed.isEmpty)
        #expect(RT.exists(a))
    }

    @Test func adoptedFilesAreMoved() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 40 * RT.day, now: now)
        try RT.shot("young.png", in: dir, age: 2 * RT.day, now: now)
        let policy = RT.policy(dir)
        let ledger = try RT.ledger()

        let preview = try #require(RT.scan(dir, policy: policy, ledger: await ledger.entries(), now: now).success)
        #expect(preview.olderNotTrackedFiles.map(\.url.lastPathComponent) == ["a.png"])
        let adoptable = RetentionScanner.stillAdoptable(
            preview.olderNotTrackedFiles, ledger: await ledger.entries(), now: now, days: policy.days)
        #expect(adoptable.map(\.url.lastPathComponent) == ["a.png"])
        await ledger.adopt(adoptable)
        #expect(RetentionScanner.stillAdoptable(
            preview.olderNotTrackedFiles, ledger: await ledger.entries(), now: now, days: policy.days).isEmpty)

        let scan = try #require(RT.scan(dir, policy: policy, ledger: await ledger.entries(), now: now).success)
        #expect(scan.expired.map(\.url.lastPathComponent) == ["a.png"])
        #expect(scan.expiredBytes == Int64(RT.png.count))
        #expect(scan.olderNotTracked == 0)

        let trasher = try FakeTrasher()
        let result = try await RT.runner(trasher, ledger).run(scan, now: now)
        #expect(result.moved == 1)
        #expect(result.movedBytes == Int64(RT.png.count))
        #expect(result.failed == 0)
        #expect(!RT.exists(a))
        #expect(trasher.trashed == ["a.png"])
        #expect(await ledger.entries().isEmpty)
    }

    @Test func disabledPolicyExpiresNothing() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 400 * RT.day, now: now)
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir, enabled: false), ledger: [RT.entry(a)], now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.expiredBytes == 0)
        #expect(scan.pending == 0)
        // The default policy (disabled, never confirmed) does not fail either.
        #expect(RT.scan(dir, policy: .default, ledger: [RT.entry(a)], now: now).success?.expired.isEmpty == true)
    }

    @Test func expiresStrictlyOlderThanDays() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let exact = try RT.shot("exact.png", in: dir, age: 30 * RT.day, now: now)
        let older = try RT.shot("older.png", in: dir, age: 30 * RT.day + 1, now: now)
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir, days: 30), ledger: [RT.entry(exact), RT.entry(older)], now: now).success)
        #expect(scan.expired.map(\.url.lastPathComponent) == ["older.png"])
    }

    @Test func futureCreationDateIsSkipped() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let future = try RT.shot("future.png", in: dir, age: -400 * RT.day, now: now)
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir, days: 1), ledger: [RT.entry(future)], now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.olderNotTracked == 0)
    }

    @Test func unmarkedAndQuarantinedNeverExpire() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let age = 40 * RT.day
        let files = [
            try RT.shot("unmarked.png", in: dir, age: age, now: now, marker: .none),
            try RT.shot("false.png", in: dir, age: age, now: now, marker: .false),
            try RT.shot("notype.png", in: dir, age: age, now: now, captureType: false),
            try RT.shot("quarantined.png", in: dir, age: age, now: now, quarantine: true),
            try RT.shot("downloaded.png", in: dir, age: age, now: now, whereFroms: true),
        ]
        // Even with ledger entries for them (which `record` would never create).
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: files.map(RT.entry), now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.olderNotTracked == 0)
        #expect(scan.skippedUnmarkedImages == 5)
    }

    @Test func skippedCountsOnlyImageFiles() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        try RT.shot("plain.png", in: dir, age: 0, now: now, marker: .none)
        try RT.shot("photo.jpg", in: dir, age: 0, now: now, marker: .none)
        try RT.shot("notes.txt", in: dir, age: 0, now: now, marker: .none)
        try RT.shot("clip.mov", in: dir, age: 0, now: now, marker: .none)
        try RT.shot(".hidden.png", in: dir, age: 0, now: now, marker: .none)
        try RT.shot("marked.png", in: dir, age: 0, now: now)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder.png"), withIntermediateDirectories: false)
        let target = try RT.shot("elsewhere.png", in: try Fixtures.makeDir(), age: 0, now: now, marker: .none)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.png"), withDestinationURL: target)
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: [], now: now).success)
        #expect(scan.skippedUnmarkedImages == 2)
    }

    @Test func neverExpiresMovSubfolderOrSymlink() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let age = 40 * RT.day
        let mov = try RT.shot("rec.mov", in: dir, age: age, now: now)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let nested = try RT.shot("nested.png", in: sub, age: age, now: now)
        let target = try RT.shot("target.png", in: try Fixtures.makeDir(), age: age, now: now)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let targetEntry = RT.entry(target)
        let ledger = [
            LedgerEntry(path: ConfirmedFolder.of(dir)!.path + "/rec.mov", resourceID: Data([1]), created: now.addingTimeInterval(-age), size: 1),
            RT.entry(nested),
            LedgerEntry(path: ConfirmedFolder.of(dir)!.path + "/link.png", resourceID: targetEntry.resourceID, created: targetEntry.created, size: targetEntry.size),
            targetEntry,
        ]
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: ledger, now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.skippedUnmarkedImages == 0)
        #expect(scan.olderNotTracked == 0)
        #expect(RT.exists(mov) && RT.exists(nested) && RT.exists(link))
    }

    @Test func retentionPausesWhenFolderDiffersFromConfirmed() throws {
        let a = try Fixtures.makeDir()
        let b = try Fixtures.makeDir()
        let now = RT.now()
        let shot = try RT.shot("x.png", in: b, age: 40 * RT.day, now: now)
        #expect(RT.scan(b, policy: RT.policy(a), ledger: [RT.entry(shot)], now: now) == .failure(.notConfirmed))
        let unconfirmed = RetentionPolicy(enabled: true, days: 30, confirmed: nil)
        #expect(RT.scan(b, policy: unconfirmed, ledger: [RT.entry(shot)], now: now) == .failure(.notConfirmed))
        // A missing folder (macOS then falls back to the Desktop, F14) is never confirmed either.
        let missing = b.appendingPathComponent("gone", isDirectory: true)
        #expect(RT.scan(missing, policy: unconfirmed, ledger: [], now: now) == .failure(.notConfirmed))
        // Same folder through a symlink is the same confirmed folder.
        let link = try Fixtures.makeDir().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        let scan = try #require(RT.scan(link, policy: RT.policy(b), ledger: [RT.entry(shot)], now: now).success)
        #expect(scan.expired.count == 1)
    }

    @Test func capsAt500AndReportsPending() throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        var entries: [LedgerEntry] = []
        for i in 0..<503 {
            let url = try RT.shot("s\(i).png", in: dir, age: 40 * RT.day + TimeInterval(i), now: now)
            entries.append(RT.entry(url))
        }
        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: entries, now: now).success)
        #expect(scan.expired.count == 500)
        #expect(scan.pending == 3)
        #expect(scan.expiredBytes == Int64(500 * RT.png.count))
        // Oldest first: the three youngest are the ones left pending.
        #expect(Set(scan.expired.map(\.url.lastPathComponent)).isDisjoint(with: ["s0.png", "s1.png", "s2.png"]))
    }
}
