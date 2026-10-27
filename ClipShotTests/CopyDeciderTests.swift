import Foundation
import Testing
@testable import ClipShot

struct CopyDeciderTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func file(
        _ name: String = "a.png", created: TimeInterval = 0, modified: TimeInterval = 0, shot: Bool = true
    ) -> CaptureFile {
        CaptureFile(
            url: URL(fileURLWithPath: "/tmp/x/\(name)"), created: now.addingTimeInterval(created),
            modified: now.addingTimeInterval(modified), size: 1, resourceID: Data([1]), isScreenshot: shot)
    }

    @Test func copiesFreshScreenshotOnce() {
        var d = CopyDecider()
        let f = file(created: -1, modified: -1)
        let r1 = d.shouldCopy(f, now: now)
        #expect(r1)
        let r2 = d.shouldCopy(f, now: now)
        #expect(!r2)
    }
    @Test func wouldCopyDoesNotRecord() {
        var d = CopyDecider()
        let f = file(created: -1, modified: -1)
        #expect(d.wouldCopy(f, now: now))
        #expect(d.wouldCopy(f, now: now))
        let first = d.shouldCopy(f, now: now)
        #expect(first)
        #expect(!d.wouldCopy(f, now: now))
        #expect(!d.wouldCopy(file(created: -1, modified: -1, shot: false), now: now))
    }
    @Test func copiesAgainWhenModifiedChangesInsideWindow() {
        var d = CopyDecider()
        let r3 = d.shouldCopy(file(created: -5, modified: -5), now: now)
        #expect(r3)
        let r4 = d.shouldCopy(file(created: -5, modified: -2), now: now)
        #expect(r4)
    }
    @Test func skipsFinderDuplicateOfOldScreenshot() {
        var d = CopyDecider()
        let r5 = d.shouldCopy(file(created: 0, modified: -2 * 86400), now: now)
        #expect(!r5)
    }
    @Test func boundaryAt30Seconds() {
        var d = CopyDecider()
        let r6 = d.shouldCopy(file("a.png", created: -30, modified: -30), now: now)
        #expect(r6)
        let r7 = d.shouldCopy(file("b.png", created: -31, modified: -31), now: now)
        #expect(!r7)
    }
    @Test func rejectsNonScreenshotAndFutureCreated() {
        var d = CopyDecider()
        let r8 = d.shouldCopy(file(shot: false), now: now)
        #expect(!r8)
        let r9 = d.shouldCopy(file("f.png", created: 2, modified: 0), now: now)
        #expect(!r9)
        let r10 = d.shouldCopy(file("g.png", created: 1, modified: 0), now: now)
        #expect(r10)
    }
    @Test func seededFilesAreNeverCopied() {
        var d = CopyDecider()
        let f = file(created: -1, modified: -1)
        d.seed([f], now: now)
        let r11 = d.shouldCopy(f, now: now)
        #expect(!r11)
    }
    @Test func pruneForgetsOldEntries() {
        var d = CopyDecider()
        let f = file(created: -1, modified: -1)
        let r12 = d.shouldCopy(f, now: now)
        #expect(r12)
        d.prune(now: now.addingTimeInterval(61))
        let r13 = d.shouldCopy(f, now: now)
        #expect(r13)
    }

    /// Spotlight held `screencapture` up for 69 s between writing the hidden file and the
    /// rename (2026-10-27): the window counts from when the file appeared.
    @Test func lateCaptureIsJudgedFromWhenItAppeared() {
        var d = CopyDecider()
        let late = file(created: -69, modified: -69)
        #expect(!d.wouldCopy(late, now: now))
        let copied = d.shouldCopy(late, now: now, hiddenFor: 69)
        #expect(copied)
        #expect(!d.wouldCopy(late, now: now, hiddenFor: 69))
        #expect(CopyDecider.isFresh(late, now: now.addingTimeInterval(30), hiddenFor: 69))
        #expect(!CopyDecider.isFresh(late, now: now.addingTimeInterval(31), hiddenFor: 69))
    }
    /// A sync tool writes a hidden file, sets the original's old modification date, renames it.
    @Test func lateFileWithOldModificationIsNotCopied() {
        var d = CopyDecider()
        let synced = d.shouldCopy(file(created: -69, modified: -2 * 86400), now: now, hiddenFor: 69)
        #expect(!synced)
    }
    /// A late copy is remembered for `memory` after it was copied, not after it was written:
    /// the rescans after it must not copy it again.
    @Test func pruneKeepsLateCopyForItsMemory() {
        var d = CopyDecider()
        let late = file(created: -69, modified: -69)
        let first = d.shouldCopy(late, now: now, hiddenFor: 69)
        #expect(first)
        d.prune(now: now.addingTimeInterval(3))
        let again = d.shouldCopy(late, now: now.addingTimeInterval(3), hiddenFor: 69)
        #expect(!again)
    }

    @Test func skipsMovSymlinkHidden() throws {
        let dir = try Fixtures.makeDir()
        let png = try Fixtures.write(named: "ok.png", in: dir)
        let mov = try Fixtures.write(named: "rec.mov", in: dir)
        let hidden = try Fixtures.write(named: ".hidden.png", in: dir)
        let txt = try Fixtures.write(named: "n.txt", in: dir)
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: png)
        let subdir = dir.appendingPathComponent("d.png")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
        #expect(CaptureFile.inspect(png)?.isScreenshot == true)
        for u in [mov, hidden, txt, link, subdir] { #expect(CaptureFile.inspect(u) == nil) }
    }
    @Test func upperCaseExtensionAndUnmarkedImage() throws {
        let dir = try Fixtures.makeDir()
        let a = try Fixtures.write(named: "A.PNG", in: dir)
        let b = try Fixtures.write(named: "b.png", in: dir, marker: .none)
        #expect(CaptureFile.inspect(a)?.isScreenshot == true)
        #expect(CaptureFile.inspect(b)?.isScreenshot == false)
    }
    @Test func resourceIDStableAcrossRenameDifferentAfterReplace() throws {
        let dir = try Fixtures.makeDir()
        let a = try Fixtures.write(named: "a.png", in: dir)
        let first = try #require(CaptureFile.inspect(a))
        #expect(CaptureFile.inspect(a)?.resourceID == first.resourceID)
        let renamed = dir.appendingPathComponent("r.png")
        try FileManager.default.moveItem(at: a, to: renamed)
        #expect(CaptureFile.inspect(renamed)?.resourceID == first.resourceID)
        let again = try Fixtures.write(named: "r.png", in: dir)
        #expect(CaptureFile.inspect(again)?.resourceID != first.resourceID)
    }
    @Test func datesComeFromFile() throws {
        let dir = try Fixtures.makeDir()
        let old = Date(timeIntervalSinceNow: -3600)
        let u = try Fixtures.write(named: "a.png", in: dir, created: old, modified: old)
        let f = try #require(CaptureFile.inspect(u))
        #expect(abs(f.created.timeIntervalSince(old)) < 1)
        #expect(abs(f.modified.timeIntervalSince(old)) < 1)
        #expect(f.size > 0)
    }
}
