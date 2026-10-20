import Foundation
import Synchronization
import Testing
@testable import ClipShot

/// Which files a pass reads markers for (P1), and the files it refuses to read (S3).
/// Rescans are released at once and the tests wait on the coordinator's own counters, so a
/// "nothing happened" check runs after the passes it is about, never after a fixed sleep.
@MainActor
struct CopyPassTests {
    /// The names whose marker was read, each time it was.
    final class MarkerReads: Sendable {
        private let names = Mutex<[String]>([])

        func read(_ url: URL) -> Bool {
            names.withLock { $0.append(url.lastPathComponent) }
            return CaptureMarker.isScreenshot(url)
        }

        func count(_ name: String) -> Int { names.withLock { $0.filter { $0 == name }.count } }
    }

    private static let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)

    @Test func anOldFileIsNeverMarkerReadInAPass() async throws {
        let reads = MarkerReads()
        let h = try CoordinatorHarness(sleepUntil: { _ in }, readMarker: { reads.read($0) })
        defer { h.coordinator.stop() }
        try Fixtures.write(named: "Old.png", in: h.folder, created: Self.twoDaysAgo, modified: Self.twoDaysAgo)
        #expect(await h.start())
        let shot = CoordinatorHarness.png(30)
        try Fixtures.write(named: "New.png", contents: shot, in: h.folder)
        #expect(await eventually { await h.writes == [shot] })

        // A Finder copy of an old screenshot keeps its dates: new to the folder, so its
        // marker is read once, and never again once it is known.
        try Fixtures.write(named: "Old copy.png", in: h.folder, created: Self.twoDaysAgo, modified: Self.twoDaysAgo)
        #expect(await eventually { reads.count("Old copy.png") == 1 })
        let events = h.coordinator.eventsHandled
        try Fixtures.write(named: "notes.png", contents: CoordinatorHarness.png(31), in: h.folder, marker: .none)
        #expect(await h.settled(after: events))

        #expect(reads.count("Old.png") == 0)
        #expect(reads.count("Old copy.png") == 1)
        #expect(reads.count("New.png") >= 1)
        #expect(h.writes == [shot])
    }

    /// P2: the 1 s poll re-reads the folder pref, but runs a pass only while a file is open
    /// in Markup.
    @Test func thePollRunsAPassOnlyWhileAFileIsOpenInMarkup() async throws {
        let h = try CoordinatorHarness(sleepUntil: { _ in })
        defer { h.coordinator.stop() }
        #expect(await h.start())
        #expect(await eventually { await h.coordinator.isIdle })
        let passes = h.coordinator.passesFinished
        let polls = h.coordinator.pollsFinished
        #expect(await eventually { await h.coordinator.pollsFinished >= polls + 3 })
        #expect(h.coordinator.passesFinished == passes)

        let url = try Fixtures.write(named: "Edited.png", in: h.folder, created: Self.twoDaysAgo, modified: Self.twoDaysAgo)
        #expect(await eventually { await h.coordinator.isIdle })
        h.edits.begin(try #require(CaptureFile.inspect(url)))
        let editing = h.coordinator.passesFinished
        #expect(await eventually { await h.coordinator.passesFinished >= editing + 3 })
    }

    /// S3: a fresh screenshot another user wrote into a shared folder is skipped quietly:
    /// not copied, not recorded, no "could not copy".
    @Test func anotherUsersScreenshotIsSkippedQuietly() async throws {
        let reads = MarkerReads()
        let h = try CoordinatorHarness(
            sleepUntil: { _ in }, readMarker: { reads.read($0) }, trust: FileTrust.Policy(owner: getuid() + 1))
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let events = h.coordinator.eventsHandled
        try Fixtures.write(named: "Planted.png", contents: CoordinatorHarness.png(32), in: h.folder)
        #expect(await h.settled(after: events))
        #expect(h.writes.isEmpty)
        #expect(h.failures == 0)
        #expect(reads.count("Planted.png") == 0)
        #expect(await h.ledgerNames().isEmpty)
    }

    /// S3: a screenshot the copy refuses to read (here: over the size limit) is not copied
    /// and not reported as a failed copy, even after the last rescan.
    @Test func aRefusedScreenshotIsNotAFailedCopy() async throws {
        let h = try CoordinatorHarness(sleepUntil: { _ in }, trust: FileTrust.Policy(maxBytes: 10))
        defer { h.coordinator.stop() }
        #expect(await h.start())
        let events = h.coordinator.eventsHandled
        try Fixtures.write(named: "Huge.png", contents: CoordinatorHarness.png(33), in: h.folder)
        #expect(await h.settled(after: events))
        #expect(h.writes.isEmpty)
        #expect(h.failures == 0)
    }
}
