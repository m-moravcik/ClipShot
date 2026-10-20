import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// A clock the test moves by hand.
final class ManualClock: Sendable {
    private let now: Mutex<Date>

    init(_ start: Date = Date()) { now = Mutex(start) }

    var date: Date { now.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { now.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// Writes new contents into the same file, as an editor that saves in place does: the inode,
/// the birth time and the xattrs stay, the modification time is now.
func rewriteInPlace(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
    try handle.close()
}

struct EditSessionTests {
    @Test func sessionExpiresAfter30Minutes() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.png", in: dir)
        let file = try #require(CaptureFile.inspect(url))
        let clock = ManualClock()
        let edits = EditSession(clock: { clock.date })
        #expect(!edits.isEditing(file))
        #expect(!edits.isActive)

        edits.begin(file)
        #expect(edits.isEditing(file))
        clock.advance(29 * 60)
        #expect(edits.isEditing(file))
        clock.advance(2 * 60)
        #expect(!edits.isEditing(file), "31 minutes after it began")
        #expect(!edits.isActive)

        let token = edits.begin(file)
        edits.end(token)
        #expect(!edits.isEditing(file), "the editor closed")
    }

    @Test func reopenedEditKeepsNewSession() throws {
        let dir = try Fixtures.makeDir()
        let file = try #require(CaptureFile.inspect(try Fixtures.write(named: "Screenshot.png", in: dir)))
        let edits = EditSession()
        let first = edits.begin(file)
        // Opened again before the first editor's grace period ran out.
        let second = edits.begin(file)
        edits.end(first)
        #expect(edits.isEditing(file), "the first edit's end leaves the new session open")
        edits.end(second)
        #expect(!edits.isEditing(file))
    }

    @Test func sessionMatchesByPathOrInode() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.png", in: dir)
        let file = try #require(CaptureFile.inspect(url))
        let edits = EditSession()
        edits.begin(file)
        // Saved by replacing the file: same path, another inode.
        #expect(edits.isEditing(path: url.path, resourceID: Data([1, 2, 3])))
        // The other spelling of the same path.
        #expect(edits.isEditing(path: dir.appendingPathComponent("./Screenshot.png").path, resourceID: Data()))
        // Another file in the folder.
        let other = try #require(CaptureFile.inspect(try Fixtures.write(named: "Other.png", in: dir)))
        #expect(!edits.isEditing(other))
    }

    @Test func deciderExemptsOnlyEditedFilesFromTheBirthRule() throws {
        let now = Date()
        let dir = try Fixtures.makeDir()
        let old = try #require(CaptureFile.inspect(try Fixtures.write(
            named: "Old.png", in: dir, created: now.addingTimeInterval(-600), modified: now.addingTimeInterval(-2))))
        let unmarked = try #require(CaptureFile.inspect(try Fixtures.write(
            named: "Unmarked.png", in: dir, marker: .none, captureType: false,
            created: now.addingTimeInterval(-600), modified: now.addingTimeInterval(-2))))
        let stale = try #require(CaptureFile.inspect(try Fixtures.write(
            named: "Stale.png", in: dir, created: now.addingTimeInterval(-600), modified: now.addingTimeInterval(-60))))
        var decider = CopyDecider()
        #expect(!decider.wouldCopy(old, now: now), "born 10 minutes ago")
        #expect(decider.wouldCopy(old, now: now, editing: true))
        #expect(decider.wouldCopy(unmarked, now: now, editing: true), "an editor may drop the marker")
        #expect(!decider.wouldCopy(stale, now: now, editing: true), "not written within the window")
        let first = decider.shouldCopy(old, now: now, editing: true)
        let second = decider.shouldCopy(old, now: now, editing: true)
        #expect(first)
        #expect(!second, "the same version only once")
    }
}

@MainActor
struct EditSessionCopyTests {
    private static let old: TimeInterval = 120

    @Test func editedFileCopiesAfter30sWhileSessionOpen() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        let then = Date().addingTimeInterval(-Self.old)
        let url = try Fixtures.write(named: "Screenshot.png", in: h.folder, created: then, modified: then)
        #expect(await h.start())
        let file = try #require(CaptureFile.inspect(url))
        h.edits.begin(file)

        // Markup saves in place two minutes after the capture: no folder event, birth unchanged.
        let edited = CoordinatorHarness.png(51)
        try rewriteInPlace(url, with: edited)
        #expect(await eventually { await h.writes == [edited] })

        // A save that also drops the marker still copies while the session is open.
        let again = CoordinatorHarness.png(52)
        try rewriteInPlace(url, with: again)
        #expect(removexattr(url.path, CaptureMarker.captureFlag, XATTR_NOFOLLOW) == 0)
        #expect(await eventually { await h.writes == [edited, again] })
    }

    @Test func halfWrittenEditIsRetriedNotReportedAsFailed() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        let then = Date().addingTimeInterval(-Self.old)
        let url = try Fixtures.write(named: "Screenshot.png", in: h.folder, created: then, modified: then)
        #expect(await h.start())
        h.edits.begin(try #require(CaptureFile.inspect(url)))

        // The editor has written half the file: the poll's passes see it and must not give up.
        let edited = CoordinatorHarness.png(54)
        try rewriteInPlace(url, with: edited.prefix(edited.count / 2))
        // Several of the poll's passes, counted, not timed.
        let passes = h.coordinator.passesFinished
        #expect(await eventually { await h.coordinator.passesFinished >= passes + 4 })
        #expect(h.failures == 0)
        #expect(h.writes.isEmpty)

        try rewriteInPlace(url, with: edited)
        #expect(await eventually { await h.writes == [edited] })
        #expect(h.failures == 0)
    }

    @Test func oldFileOutsideSessionNeverCopies() async throws {
        let h = try CoordinatorHarness()
        defer { h.coordinator.stop() }
        let then = Date().addingTimeInterval(-Self.old)
        let url = try Fixtures.write(named: "Screenshot.png", in: h.folder, created: then, modified: then)
        let other = try Fixtures.write(named: "Other.png", in: h.folder, created: then, modified: then)
        #expect(await h.start())
        // Another file is being edited; this one is not.
        h.edits.begin(try #require(CaptureFile.inspect(other)))
        try rewriteInPlace(url, with: CoordinatorHarness.png(53))
        // A folder event, so a pass certainly runs: wait for it and all its rescans.
        let events = h.coordinator.eventsHandled
        try Data("x".utf8).write(to: h.folder.appendingPathComponent("note.txt"))
        #expect(await h.settled(after: events))
        #expect(h.writes.isEmpty)
    }
}
