import Foundation
import Testing
@testable import ClipShot

struct StagedCapturesTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func file(
        _ name: String, created: TimeInterval = 0, modified: TimeInterval = 0, id: UInt8 = 7, owned: Bool = true
    ) -> CaptureFile {
        CaptureFile(
            url: URL(fileURLWithPath: "/tmp/x/\(name)"), created: now.addingTimeInterval(created),
            modified: now.addingTimeInterval(modified), size: 1, resourceID: Data([id]), isScreenshot: false,
            isOwnedByUser: owned)
    }

    @Test func measuresHowLongAFileWasHidden() {
        var staged = StagedCaptures()
        staged.saw(file(".Screenshot.png", created: -0.1), now: now)
        let final = file("Screenshot.png", created: -0.1)
        #expect(staged.hiddenFor(final, now: now.addingTimeInterval(69)) == 69)
        #expect(staged.hiddenFor(file("Other.png", created: -0.1, id: 8), now: now.addingTimeInterval(69)) == 0)
    }

    @Test func firstSightingCounts() {
        var staged = StagedCaptures()
        staged.saw(file(".a.png-XYZ"), now: now)
        staged.saw(file(".a.png"), now: now.addingTimeInterval(5))
        #expect(staged.hiddenFor(file("a.png"), now: now.addingTimeInterval(69)) == 69)
    }

    @Test func appearanceFixesTheDelayForLaterRescans() {
        var staged = StagedCaptures()
        staged.saw(file(".a.png"), now: now)
        let final = file("a.png")
        staged.appeared(final, hiddenFor: 69)
        #expect(staged.hiddenFor(final, now: now.addingTimeInterval(72)) == 69)
        // Only the first listing under the final name measures it.
        staged.appeared(final, hiddenFor: 72)
        #expect(staged.hiddenFor(final, now: now.addingTimeInterval(72)) == 69)
    }

    @Test func inodeReusedByAnotherFileIsNotLate() {
        var staged = StagedCaptures()
        staged.saw(file(".a.png", created: 0), now: now)
        #expect(staged.hiddenFor(file("b.png", created: 40), now: now.addingTimeInterval(69)) == 0)
    }

    @Test func staleOrForeignHiddenFilesAreNotStaged() {
        var staged = StagedCaptures()
        staged.saw(file(".DS_Store", created: -86_400, modified: 0, id: 1), now: now)
        staged.saw(file(".b.png", id: 2, owned: false), now: now)
        #expect(staged.hiddenFor(file("x.png", created: -86_400, id: 1), now: now.addingTimeInterval(5)) == 0)
        #expect(staged.hiddenFor(file("b.png", id: 2), now: now.addingTimeInterval(5)) == 0)
    }

    @Test func hiddenFilesPresentWhenWatchingStartsAreNotStaged() {
        var staged = StagedCaptures(present: [file(".early.png", id: 1)])
        staged.saw(file(".early.png", id: 1), now: now.addingTimeInterval(5))
        #expect(staged.hiddenFor(file("early.png", id: 1), now: now.addingTimeInterval(40)) == 0)
        // The inode reused by a later capture is staged as usual.
        staged.saw(file(".later.png", created: 10, modified: 10, id: 1), now: now.addingTimeInterval(10))
        #expect(staged.hiddenFor(file("later.png", created: 10, id: 1), now: now.addingTimeInterval(50)) == 40)
    }

    @Test func excludedHiddenFilesAreNotStaged() {
        var staged = StagedCaptures()
        staged.exclude(file(".paused.png", id: 1))
        staged.saw(file(".paused.png", id: 1), now: now.addingTimeInterval(5))
        #expect(staged.hiddenFor(file("paused.png", id: 1), now: now.addingTimeInterval(40)) == 0)
        // A file staged before the exclusion stays staged.
        staged.saw(file(".before.png", id: 2), now: now)
        staged.exclude(file(".before.png", id: 2))
        #expect(staged.hiddenFor(file("before.png", id: 2), now: now.addingTimeInterval(40)) == 40)
    }

    @Test func hiddenLongerThanTheLimitIsNotLate() {
        var staged = StagedCaptures()
        staged.saw(file(".a.png"), now: now)
        let final = file("a.png")
        #expect(staged.hiddenFor(final, now: now.addingTimeInterval(StagedCaptures.limit)) == StagedCaptures.limit)
        #expect(staged.hiddenFor(final, now: now.addingTimeInterval(StagedCaptures.limit + 1)) == 0)
    }

    @Test func pruneForgetsUnclaimedAndSettledEntries() {
        var staged = StagedCaptures()
        staged.saw(file(".never.png", id: 1), now: now)
        staged.saw(file(".late.png", id: 2), now: now)
        let late = file("late.png", id: 2)
        staged.appeared(late, hiddenFor: 69)
        staged.prune(now: now.addingTimeInterval(69 + CopyDecider.memory))
        #expect(staged.hiddenFor(late, now: now.addingTimeInterval(69 + CopyDecider.memory)) == 69)
        staged.prune(now: now.addingTimeInterval(69 + CopyDecider.memory + 1))
        #expect(staged.hiddenFor(late, now: now.addingTimeInterval(70)) == 0)
        #expect(staged.hiddenFor(file("never.png", id: 1), now: now.addingTimeInterval(StagedCaptures.limit)) > 0)
        staged.prune(now: now.addingTimeInterval(StagedCaptures.limit + 1))
        #expect(staged.hiddenFor(file("never.png", id: 1), now: now.addingTimeInterval(StagedCaptures.limit)) == 0)
    }

    @Test func temporaryStatKeepsTheInodeAcrossTheRename() throws {
        let dir = try Fixtures.makeDir()
        let temp = dir.appendingPathComponent("..Screenshot.png-AbC123")
        try Fixtures.pngImage().write(to: temp)
        let hidden = try #require(CaptureFile.statTemporary(temp))
        #expect(!hidden.isScreenshot)
        #expect(CaptureFile.stat(temp) == nil)
        let final = dir.appendingPathComponent("Screenshot.png")
        #expect(rename(temp.path, final.path) == 0)
        #expect(CaptureFile.statTemporary(final) == nil)
        let visible = try #require(CaptureFile.stat(final))
        #expect(visible.resourceID == hidden.resourceID)
        #expect(visible.created == hidden.created)
    }
}
