import Foundation
import Testing
@testable import ClipShot

struct ScreenshotLedgerTests {
    @Test func ledgerPersistsWith0600AndPrunesMissing() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 0, now: now)
        let b = try RT.shot("b.png", in: dir, age: 0, now: now)
        let fileURL = try Fixtures.makeDir().appendingPathComponent("Support/ledger.json")
        let ledger = ScreenshotLedger(fileURL: fileURL)
        await ledger.record(RT.file(a))
        await ledger.record(RT.file(b))

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(await ScreenshotLedger(fileURL: fileURL).entries().count == 2)

        // b leaves the folder (moved elsewhere): its entry is pruned.
        let away = try Fixtures.makeDir().appendingPathComponent("b.png")
        #expect(rename(b.path, away.path) == 0)
        await ledger.prune()
        let reloaded = await ScreenshotLedger(fileURL: fileURL).entries()
        #expect(reloaded.map(\.path) == [RT.entry(a).path])
        let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((after[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func renamedLedgerEntryIsKept() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 40 * RT.day, now: now)
        let ledger = try RT.ledger()
        await ledger.record(RT.file(a))

        let renamed = dir.appendingPathComponent("keep me.png")
        #expect(rename(a.path, renamed.path) == 0)
        // Even if the watcher reports the renamed file as fresh, the rename means "keep".
        await ledger.record(RT.file(renamed))
        #expect(await ledger.entries().isEmpty)

        let scan = try #require(RT.scan(dir, policy: RT.policy(dir), ledger: await ledger.entries(), now: now).success)
        #expect(scan.expired.isEmpty)
        #expect(scan.olderNotTracked == 1)
        #expect(RT.exists(renamed))
    }

    @Test func pruneDropsEntryWhenPathHoldsAnotherFile() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let a = try RT.shot("a.png", in: dir, age: 0, now: now)
        let ledger = try RT.ledger()
        await ledger.record(RT.file(a))
        let moved = try Fixtures.makeDir().appendingPathComponent("a.png")
        #expect(rename(a.path, moved.path) == 0)
        try RT.shot("a.png", in: dir, age: 0, now: now)   // a new inode at the same path
        await ledger.prune()
        #expect(await ledger.entries().isEmpty)
    }

    @Test func recordIgnoresFilesThatAreNotScreenshots() async throws {
        let dir = try Fixtures.makeDir()
        let now = RT.now()
        let ledger = try RT.ledger()
        await ledger.record(RT.file(try RT.shot("u.png", in: dir, age: 0, now: now, marker: .none)))
        await ledger.adopt([RT.file(try RT.shot("q.png", in: dir, age: 0, now: now, quarantine: true))])
        #expect(await ledger.entries().isEmpty)
    }

    @Test func corruptLedgerLoadsEmpty() async throws {
        let fileURL = try Fixtures.makeDir().appendingPathComponent("ledger.json")
        try Data("not json".utf8).write(to: fileURL)
        #expect(await ScreenshotLedger(fileURL: fileURL, log: try RT.testLog()).entries().isEmpty)
    }

    @Test func policyDefaultsAndClampsDays() throws {
        #expect(RetentionPolicy.default == RetentionPolicy(enabled: false, days: 30, confirmed: nil))
        #expect(RetentionPolicy.presets == [7, 14, 30, 60, 90])
        #expect(RetentionPolicy(enabled: true, days: 0, confirmed: nil).days == 1)
        var policy = RetentionPolicy(enabled: true, days: 99_999, confirmed: nil)
        #expect(policy.days == 3650)
        policy.days = -5
        #expect(policy.days == 1)
        let json = Data(#"{"enabled":true,"days":0}"#.utf8)
        #expect(try JSONDecoder().decode(RetentionPolicy.self, from: json).days == 1)
    }

    @Test func confirmedFolderResolvesSymlinksAndTrailingSlash() throws {
        let dir = try Fixtures.makeDir()
        let link = try Fixtures.makeDir().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let direct = try #require(ConfirmedFolder.of(dir))
        #expect(ConfirmedFolder.of(link) == direct)
        #expect(ConfirmedFolder.of(URL(fileURLWithPath: dir.path + "/")) == direct)
        #expect(direct.path.hasPrefix("/private/"))
        #expect(ConfirmedFolder.of(dir.appendingPathComponent("missing")) == nil)
    }
}
