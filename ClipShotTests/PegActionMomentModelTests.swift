import Foundation
import Testing
@testable import ClipShot

/// Peg answers the user's own actions in the menu bar: Move to Trash lets the picture go,
/// Undo grips it again, the click that opens the popover squeezes the peg. Retention and
/// "Also clean up" never play anything; a higher moment is never cut short by a lower one,
/// and one that replaces another starts from the pose on show.
@MainActor
struct PegActionMomentModelTests {
    /// A started harness with a screenshot ClipShot saw being taken, its copy played out.
    private func tracked(_ h: ModelHarness, _ name: String = "Screenshot 1.png") async throws -> CaptureFile {
        let url = try h.shoot(name)
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase > 0 : false })
        h.timer?.fire(PegFlash.steps)
        #expect(h.model.flashPhase == 0)
        return file
    }

    /// Plays the moment on show to its end and checks it ended at rest with no timer left.
    private func playOut(_ h: ModelHarness, _ moment: PegMoment, rest: StatusIconState = .idle) throws {
        let timer = try #require(h.timer)
        #expect(h.model.flashMoment == moment)
        timer.fire(moment.steps - 1)
        #expect(h.model.flashPhase == 0)
        #expect(timer.invalidated, "no timer at rest")
        #expect(h.model.iconPose == Peg.pose(rest))
        timer.fire(3)
        #expect(h.model.flashPhase == 0, "a late tick draws nothing")
    }

    // MARK: Triggers

    @Test func moveToTrashFromARowLetsThePictureGo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        let timers = h.timers.count
        await h.model.moveToTrash(file)
        #expect(h.trasher.trashed == ["Screenshot 1.png"])
        #expect(h.model.flashMoment == .release)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == nil, "started from rest")
        #expect(h.model.iconPose == Peg.pose(.idle), "it starts from the picture on show")
        #expect(h.model.iconState == .idle, "VoiceOver keeps saying copying is on")
        #expect(h.timers.count == timers + 1)
        #expect(h.timer?.interval == PegFlash.interval)
        try playOut(h, .release)
    }

    @Test func moveToTrashFromAPreviewLetsThePictureGo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file, fromPreview: UUID())
        #expect(h.trasher.trashed == ["Screenshot 1.png"])
        #expect(h.model.flashMoment == .release && h.model.flashPhase == 1)
        try playOut(h, .release)
    }

    /// While paused the dashed card is the one that drops, and Peg comes back to it.
    @Test func moveToTrashWhilePausedReturnsToTheDashedCard() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        h.preferences.copyEnabled = false
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false })
        h.timer?.fire(PegMoment.pause.steps)
        await h.model.moveToTrash(file)
        #expect(h.model.flashMoment == .release)
        #expect(h.model.iconPose == Peg.pose(.paused))
        try playOut(h, .release, rest: .paused)
    }

    /// A move that did not happen plays nothing: the note says why, Peg stays still.
    @Test func aRefusedMoveToTrashPlaysNothing() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let old = Date().addingTimeInterval(-3_600)
        let untracked = try Fixtures.write(named: "Before.png", in: h.folder, created: old, modified: old)
        #expect(await h.start())
        let timers = h.timers.count
        await h.model.moveToTrash(try #require(CaptureFile.inspect(untracked)))
        #expect(h.model.actionNote != nil)
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.count == timers)
    }

    @Test func undoGripsThePictureAgain() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        try playOut(h, .release)
        await h.model.putBack()
        #expect(h.model.undoable == nil)
        #expect(h.model.flashMoment == .grip)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == nil)
        try playOut(h, .grip)
    }

    /// An Undo that fails (its place is taken) plays nothing.
    @Test func aFailedUndoPlaysNothing() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        try playOut(h, .release)
        try Fixtures.write(named: "Screenshot 1.png", contents: Fixtures.pngImage(size: 30), in: h.folder)
        let timers = h.timers.count
        await h.model.putBack()
        #expect(h.model.actionNote != nil)
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.count == timers)
    }

    /// Retention, Clean up now and "Also clean up N older screenshots" move files to the
    /// Trash on their own terms: Peg plays nothing for any of them, whatever the count.
    @Test func retentionAndCleanUpNeverPlay() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = Date()
        for name in ["old 1.png", "old 2.png"] {
            let url = try RT.shot(name, in: h.folder, age: 40 * RT.day, now: now)
            await h.ledger.record(RT.file(url))
        }
        let older = try RT.shot("older.png", in: h.folder, age: 50 * RT.day, now: now)
        #expect(await h.start())
        #expect(await h.model.cleanUpNow() == nil)
        h.preferences.retention = RT.policy(h.folder)
        await h.model.cleanUpNow()
        #expect(Set(h.trasher.trashed) == ["old 1.png", "old 2.png"])
        h.model.refreshPreview()
        #expect(await eventually { await h.model.retentionPreview?.success?.olderNotTracked == 1 })
        #expect(await h.model.adoptOlderScreenshots() == 1)
        await h.model.cleanUpNow()
        #expect(h.trasher.trashed.contains(older.lastPathComponent))
        // The scheduled run on wake too.
        let late = try RT.shot("late.png", in: h.folder, age: 41 * RT.day, now: now)
        await h.ledger.record(RT.file(late))
        h.wake.send()
        #expect(await eventually { await h.preferences.totals.trashed == 4 })
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.isEmpty, "no moment ever started")
    }

    /// The click that opens the popover squeezes the peg; closing plays nothing, and a
    /// report that it is still open plays nothing again.
    @Test func openingThePopoverSqueezes() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashMoment == .squeeze)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.iconPose == Peg.pose(.idle), "it starts from rest")
        #expect(h.timers.count == 1)
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashPhase == 1, "still open: no second squeeze")
        #expect(h.timers.count == 1)
        try playOut(h, .squeeze)
        h.model.popoverVisibilityChanged(false)
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.count == 1, "closing plays nothing")
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashMoment == .squeeze && h.model.flashPhase == 1, "the next open squeezes again")
    }

    /// The window is open when ordered in and key (the click that opens it, before the window
    /// server reports it unoccluded) or unoccluded; ordered out, it is closed.
    @Test func popoverOpensWithTheKeyWindowOrItsOcclusion() {
        #expect(WindowVisibilityReader.isOpen(visible: true, key: true, unoccluded: false))
        #expect(WindowVisibilityReader.isOpen(visible: true, key: false, unoccluded: true))
        #expect(WindowVisibilityReader.isOpen(visible: true, key: true, unoccluded: true))
        #expect(!WindowVisibilityReader.isOpen(visible: true, key: false, unoccluded: false))
        #expect(!WindowVisibilityReader.isOpen(visible: false, key: true, unoccluded: true))
        #expect(!WindowVisibilityReader.isOpen(visible: false, key: false, unoccluded: false))
    }

    // MARK: Precedence

    /// copy > attention > release and grip > squeeze: a Move to Trash or an open during a copy
    /// plays nothing in the menu bar, and the copy runs to its end.
    @Test func nothingLowerCutsACopyShort() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        try h.shoot("Screenshot 2.png")
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase == 1 : false })
        let timer = try #require(h.timer)
        timer.fire(10)
        await h.model.moveToTrash(file)
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashMoment == .copied)
        #expect(h.model.flashPhase == 11)
        try playOut(h, .copied)
    }

    /// A squeeze never cuts a release or a grip short.
    @Test func theSqueezeWaitsForNothingAndCutsNothing() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        h.timer?.fire(5)
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashMoment == .release)
        #expect(h.model.flashPhase == 6)
        try playOut(h, .release)
    }

    /// A copy during a release replaces it from the pose on show: the falling card keeps
    /// falling, nothing jumps, and the copy ends at rest on its one timer.
    @Test func aCopyReplacesAReleaseFromThePoseOnShow() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        let timer = try #require(h.timer)
        timer.fire(9)
        let shown = h.model.iconPose
        try h.shoot("Screenshot 2.png")
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase > 0 : false })
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == shown)
        #expect(h.model.iconPose.old == shown.card, "the card on show is the one that drops")
        #expect(h.model.iconPose.pegLift == shown.pegLift && h.model.iconPose.sag == shown.sag)
        #expect(h.timer === timer, "the same frame timer")
        try playOut(h, .copied)
    }

    /// Something first needs fixing during a grip: the swing replaces it from the pose on
    /// show; a release that comes after does not cut the swing short.
    @Test func attentionReplacesAGripAndIsNotCutShort() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        let second = try await tracked(h, "Screenshot 2.png")
        await h.model.moveToTrash(file)
        h.timer?.fire(PegMoment.release.steps)
        await h.model.putBack()
        #expect(h.model.flashMoment == .grip)
        h.timer?.fire(7)
        let shown = h.model.iconPose
        h.prefs["target"] = "clipboard"
        h.model.refreshStatus()
        #expect(await eventually { await !h.model.attentions.isEmpty })
        #expect(h.model.flashMoment == .attention)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == shown)
        #expect(h.model.iconPose == shown, "the swing starts where the grip was")
        h.timer?.fire(3)
        await h.model.moveToTrash(second)
        #expect(h.model.flashMoment == .attention, "a release does not cut the swing short")
        #expect(h.model.flashPhase == 4)
        try playOut(h, .attention, rest: .attention)
    }

    /// An Undo during a release replaces it, and a Move to Trash during a grip replaces that:
    /// equals take over, from the pose on show.
    @Test func releaseAndGripReplaceEachOther() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        h.timer?.fire(11)
        let falling = h.model.iconPose
        await h.model.putBack()
        #expect(h.model.flashMoment == .grip && h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == falling)
        #expect(h.model.iconPose.old == falling.card, "the falling card fades where it is")
        try playOut(h, .grip)
    }

    // MARK: Reduce Motion

    /// Reduce Motion: a release and a grip are each one plain hold of the key pose for the
    /// moment's length, on one timer tick; the squeeze shows nothing.
    @Test func reduceMotionHoldsTheKeyPoses() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.reduceMotion = true
        #expect(await h.start())
        let file = try await tracked(h)
        let copyHolds = h.timers.count

        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashPhase == 0, "no squeeze")
        #expect(h.timers.count == copyHolds)

        await h.model.moveToTrash(file)
        #expect(h.model.flashMoment == .release)
        #expect(h.model.iconPose == Peg.releaseKeyPose)
        let release = try #require(h.timer)
        #expect(release.interval == Design.Motion.menuBarRelease)
        release.fire()
        #expect(h.model.flashPhase == 0)
        #expect(release.invalidated)
        #expect(h.model.iconPose == Peg.pose(.idle))

        await h.model.putBack()
        #expect(h.model.flashMoment == .grip)
        #expect(h.model.iconPose == Peg.gripKeyPose(.idle))
        let grip = try #require(h.timer)
        #expect(grip.interval == Design.Motion.menuBarGrip)
        grip.fire()
        #expect(h.model.flashPhase == 0)
        #expect(grip.invalidated)
        #expect(h.model.iconPose == Peg.pose(.idle))
    }

    /// Reduce Motion: something needing attention during a release's hold shows "!" at once,
    /// ending the hold; nothing plays in its place.
    @Test func reduceMotionAttentionEndsALowerHold() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.reduceMotion = true
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        let release = try #require(h.timer)
        #expect(h.model.flashMoment == .release && h.model.flashPhase == 1)
        h.prefs["target"] = "clipboard"
        h.model.refreshStatus()
        #expect(await eventually { await !h.model.attentions.isEmpty })
        #expect(h.model.flashPhase == 0)
        #expect(release.invalidated)
        #expect(h.model.iconPose == Peg.pose(.attention))
    }
}
