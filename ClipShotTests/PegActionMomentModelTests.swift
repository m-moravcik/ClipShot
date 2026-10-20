import AppKit
import Foundation
import Testing
@testable import ClipShot

/// A borderless window that says whether it is key, for the reader's wiring test: the test
/// host is not the active app, so AppKit would not make it key.
private final class KeyableWindow: NSWindow {
    var key = false
    override var isKeyWindow: Bool { key }
}

/// What a reader reported, in order: open, and fresh.
@MainActor
private final class ReaderReports {
    var all: [(Bool, Bool)] = []
}

/// Peg answers the user's own actions in the menu bar: Move to Trash lets the picture go,
/// Undo grips it again, the click that opens the popover squeezes the peg. Retention and
/// "Also clean up" never play anything; among copy, release and grip the latest wins, a
/// change of state is never cut short by a release, grip or squeeze, and a moment that
/// replaces another starts from the pose on show.
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

    /// The two poses draw the same picture (the cards may sit in different roles).
    private func draws(_ pose: Peg.Pose, as other: Peg.Pose) throws -> Bool {
        let a = try #require(GlyphInk.unclipped(pose, pad: 8)), b = try #require(GlyphInk.unclipped(other, pad: 8))
        return zip(GlyphInk.alpha(a), GlyphInk.alpha(b)).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
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
        #expect(try draws(h.model.iconPose, as: Peg.pose(.idle)), "it starts from the picture on show")
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
        #expect(try draws(h.model.iconPose, as: Peg.pose(.paused)))
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

    /// Only a fresh open squeezes: the window coming back from occlusion while it stayed
    /// ordered in (a display asleep, another Space) reopens the popover's refresh without a click.
    @Test func anOpenWithoutAClickDoesNotSqueeze() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.popoverVisibilityChanged(true, freshOpen: false)
        #expect(h.model.popoverVisible)
        #expect(h.model.flashPhase == 0)
        #expect(h.timers.isEmpty)
    }

    /// The presence rule: ordered in after being out (or for the first time) is a fresh open;
    /// occluded and back while still ordered in is not; closing reports once.
    @Test func popoverPresenceCountsOnlyRealOpens() {
        var presence = PopoverPresence()
        #expect(presence.update(visible: false, key: false, unoccluded: false) == nil, "closed at the start")
        #expect(presence.update(visible: true, key: true, unoccluded: false) == .opened(fresh: true), "the click")
        #expect(presence.update(visible: true, key: true, unoccluded: true) == nil, "still open")
        // The display sleeps: still ordered in, no longer key or visible, then back.
        #expect(presence.update(visible: true, key: false, unoccluded: false) == .closed)
        #expect(presence.update(visible: true, key: false, unoccluded: true) == .opened(fresh: false))
        // Closed by ordering out, then a click again.
        #expect(presence.update(visible: false, key: false, unoccluded: false) == .closed)
        #expect(presence.update(visible: false, key: false, unoccluded: false) == nil)
        #expect(presence.update(visible: true, key: false, unoccluded: true) == .opened(fresh: true))
    }

    /// The reader's wiring on a real window of the test host, off screen: its becoming key is
    /// reported at once as a fresh open, before any occlusion change, and resigning key once
    /// ordered out as closed. The test host is not the active app, so the window says it is key
    /// and the notifications AppKit sends are posted as AppKit does.
    @Test func readerReportsBecomingKeyAsAFreshOpen() {
        let reports = ReaderReports()
        let window = KeyableWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 40, height: 40), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let reader = WindowVisibilityReader.ReaderView()
        reader.changed = { reports.all.append(($0, $1)) }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView?.addSubview(reader)
        #expect(reports.all.isEmpty, "not ordered in: nothing to report")
        window.orderFront(nil)
        #expect(window.isVisible)
        #expect(!window.occlusionState.contains(.visible), "off screen")
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(reports.all.count == 1)
        #expect(reports.all.first.map { $0.0 && $0.1 } == true, "a fresh open, from becoming key alone")
        // Another window's notification is not this one's.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        #expect(reports.all.count == 1)
        window.orderOut(nil)
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(reports.all.count == 2)
        #expect(reports.all.last.map { !$0.0 } == true, "closed once ordered out")
        // Ordered in and key again: a fresh open again.
        window.orderFront(nil)
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(reports.all.last.map { $0.0 && $0.1 } == true)
        window.orderOut(nil)
        window.close()
    }

    // MARK: Precedence

    /// Among copy, release and grip the latest wins: a Move to Trash right after the copy (the
    /// screenshot just taken, as from its floating preview) lets it go at once, from the pose
    /// on show, on the same frame timer; VoiceOver no longer says Copied.
    @Test func aMoveToTrashRightAfterACopyReplacesIt() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase == 1 : false })
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        let timer = try #require(h.timer)
        timer.fire(30)
        #expect(h.model.iconState == .copied)
        let shown = h.model.iconPose
        await h.model.moveToTrash(file, fromPreview: UUID())
        #expect(h.model.flashMoment == .release)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == shown)
        #expect(try draws(h.model.iconPose, as: shown), "the release starts where the copy was")
        #expect(h.model.iconState == .idle)
        #expect(h.timer === timer, "the same frame timer")
        try playOut(h, .release)
    }

    /// An Undo while a newer copy plays grips the screenshot back at once, from the pose on show.
    @Test func anUndoDuringACopyReplacesIt() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let file = try await tracked(h)
        await h.model.moveToTrash(file)
        try playOut(h, .release)
        try h.shoot("Screenshot 2.png")
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase == 1 : false })
        h.timer?.fire(20)
        let shown = h.model.iconPose
        await h.model.putBack()
        #expect(h.model.flashMoment == .grip)
        #expect(h.model.flashPhase == 1)
        #expect(h.model.flashHandoff == shown)
        try playOut(h, .grip)
    }

    /// The squeeze never cuts a copy short: opening the popover during a copy plays nothing
    /// more, and the copy runs to its end.
    @Test func theSqueezeNeverCutsACopy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase == 1 : false })
        let timer = try #require(h.timer)
        timer.fire(10)
        h.model.popoverVisibilityChanged(true)
        #expect(h.model.flashMoment == .copied)
        #expect(h.model.flashPhase == 11)
        try playOut(h, .copied)
    }

    /// Reduce Motion: a Move to Trash during the copy's hold replaces it with the release's
    /// hold, on a timer of its own length.
    @Test func reduceMotionReleaseReplacesTheCopyHold() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.reduceMotion = true
        #expect(await h.start())
        let url = try h.shoot("Screenshot 1.png")
        let file = try #require(CaptureFile.inspect(url))
        #expect(await eventually { await h.model.flashMoment == .copied ? h.model.flashPhase == 1 : false })
        #expect(await eventually { await h.ledger.contains(path: FolderGuard.canonicalPath(url), resourceID: file.resourceID) })
        let hold = try #require(h.timer)
        await h.model.moveToTrash(file)
        #expect(hold.invalidated)
        #expect(h.model.flashMoment == .release)
        #expect(h.model.flashHandoff == nil, "no hand-off without movement")
        #expect(h.model.iconPose == Peg.releaseKeyPose)
        let release = try #require(h.timer)
        #expect(release.interval == Design.Motion.menuBarRelease)
        release.fire()
        #expect(h.model.flashPhase == 0)
        #expect(h.model.iconPose == Peg.pose(.idle))
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
        #expect(h.model.iconPose.leaving == shown.old, "the card the release was dropping goes on falling")
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
        #expect(falling.old?.fall ?? 0 > 0, "the release was mid-drop")
        #expect(h.model.iconPose.leaving == falling.old, "the falling card goes on falling as it fades")
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
