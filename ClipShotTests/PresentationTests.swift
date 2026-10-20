import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ClipShot

/// English, whatever language the machine running the tests prefers.
private func en(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: "en")
    return String(localized: resource)
}

struct AttentionPresentationTests {
    let folder = URL(fileURLWithPath: "/Users/t/Pictures/Screens", isDirectory: true)

    private func text(_ attention: Attention, _ destination: CaptureDestination = .clipboard) -> String {
        en(AttentionPresentation.of(attention, destination: destination).message)
    }

    private func actions(_ attention: Attention) -> [AttentionAction] {
        AttentionPresentation.of(attention, destination: .clipboard).actions
    }

    @Test func messagesAreTheSpecCopy() {
        #expect(text(.destinationNotFile)
            == "Screenshots go to the clipboard only, so macOS saves no file and ClipShot has nothing to copy.")
        #expect(text(.folderMissing(folder)) == "The screenshot folder “Screens” was not found.")
        #expect(text(.folderAccessDenied(folder)) == "macOS blocked access to “Screens”.")
        #expect(text(.couldNotCopy) == "ClipShot saw a screenshot but could not copy it.")
        #expect(text(.retentionFolderChanged(folder))
            == "Screenshots now go to “Screens”. Retention is paused until you check what it would move.")
        #expect(text(.noTrash(folder)) == "“Screens” has no Trash, so retention is off for it.")
    }

    @Test func appDestinationIsNotCalledTheClipboard() {
        let message = text(.destinationNotFile, .other("preview"))
        #expect(!message.contains("clipboard"))
        #expect(message.contains("nothing to copy"))
    }

    @Test func buttonsAreNamedForTheirEffect() {
        #expect(actions(.destinationNotFile) == [.saveToFile])
        #expect(actions(.folderMissing(folder)) == [.chooseFolder])
        #expect(actions(.folderAccessDenied(folder)) == [.openPrivacySettings, .chooseFolder])
        #expect(actions(.couldNotCopy) == [.copyAgain, .report])
        #expect(actions(.retentionFolderChanged(folder)) == [.review])
        #expect(actions(.noTrash(folder)).isEmpty)
        #expect(AttentionAction.allTitles == [
            "Save screenshots to a file", "Choose folder…", "Open Privacy Settings", "Copy again", "Report", "Review",
        ])
    }

    @Test func topRowPlusHowManyMore() {
        let all: [Attention] = [.destinationNotFile, .couldNotCopy, .noTrash(folder)]
        let collapsed = AttentionPresentation.visible(all, expanded: false)
        #expect(collapsed.rows == [.destinationNotFile])
        #expect(collapsed.hidden == 2)
        #expect(en(Copy.Attention.more(collapsed.hidden)) == "+2 more")
        #expect(en(Copy.Attention.more(1)) == "+1 more")

        let expanded = AttentionPresentation.visible(all, expanded: true)
        #expect(expanded.rows == all)
        #expect(expanded.hidden == 0)

        #expect(AttentionPresentation.visible([.couldNotCopy], expanded: false).hidden == 0)
        #expect(AttentionPresentation.visible([], expanded: false).rows.isEmpty)
    }

    @Test func rootFolderHasAName() {
        #expect(AttentionPresentation.displayName(URL(fileURLWithPath: "/")) == "/")
        #expect(AttentionPresentation.displayName(URL(fileURLWithPath: "/Users/t/Desktop/")) == "Desktop")
    }
}

extension AttentionAction {
    static var allTitles: [String] {
        let all: [AttentionAction] = [.saveToFile, .chooseFolder, .openPrivacySettings, .copyAgain, .report, .review]
        return all.map { en($0.title) }
    }
}

struct RetentionSummaryTests {
    @Test func offPausedOrKeeping() {
        var policy = RetentionPolicy.default
        #expect(RetentionSummary.of(policy: policy, refusal: nil) == .off)
        policy.enabled = true
        #expect(RetentionSummary.of(policy: policy, refusal: nil) == .on(days: 30))
        #expect(RetentionSummary.of(policy: policy, refusal: .notConfirmed) == .paused)
        #expect(RetentionSummary.of(policy: policy, refusal: .noTrash) == .offForFolder)
        #expect(RetentionSummary.of(policy: policy, refusal: .systemOrBroad) == .offForFolder)
        #expect(en(RetentionSummary.offForFolder.title) == "Retention is off for this folder")
        #expect(en(RetentionSummary.paused.title) == "Retention is paused")
    }

    /// The popover's quiet row (A7): off says so; on says the period in the tour's sentence
    /// shape.
    @Test func retentionRowOffAndOnText() {
        #expect(en(RetentionSummary.off.title) == "Retention is off")
        #expect(en(RetentionSummary.on(days: 30).title) == "Older than 30 days go to the Trash")
        #expect(en(RetentionSummary.on(days: 1).title) == "Older than 1 day go to the Trash")
    }

    @Test func lastCleanupSaysTodayOrTheDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14)))

        #expect(en(RetentionSummary.lastCleanup(nil, now: now, calendar: calendar)) == "No cleanup needed yet")
        let todayText = en(RetentionSummary.lastCleanup(
            RetentionResult(moved: 3, movedBytes: 10, failed: 0, at: today), now: now, calendar: calendar))
        #expect(todayText.hasPrefix("Last cleanup today at "))
        #expect(todayText.hasSuffix(", 3 moved"))
        let earlierText = en(RetentionSummary.lastCleanup(
            RetentionResult(moved: 1, movedBytes: 10, failed: 0, at: earlier), now: now, calendar: calendar))
        #expect(earlierText.hasPrefix("Last cleanup "))
        #expect(!earlierText.contains("today"))
        #expect(earlierText.hasSuffix(", 1 moved"))
    }
}

struct RetentionModeTests {
    private func mode(
        watching: Bool = true, enabled: Bool, refusal: Refusal? = nil, pending: Bool = false
    ) -> RetentionMode {
        .of(isWatching: watching,
            policy: RetentionPolicy(enabled: enabled, days: 30, confirmed: nil),
            refusal: refusal, pendingEnable: pending)
    }

    @Test func states() {
        #expect(mode(watching: false, enabled: true) == .notWatching)
        #expect(mode(enabled: false) == .off)
        #expect(mode(enabled: false, pending: true) == .confirming)
        #expect(mode(enabled: true) == .on)
        #expect(mode(enabled: true, refusal: .notConfirmed) == .folderChanged)
        #expect(mode(enabled: true, refusal: .noTrash) == .refused)
        #expect(mode(enabled: true, refusal: .systemOrBroad) == .refused)
        #expect(!RetentionMode.off.showsDetails)
        #expect(RetentionMode.on.offersAdoption(olderNotTracked: 2))
        #expect(!RetentionMode.on.offersAdoption(olderNotTracked: 0))
        for mode in [RetentionMode.off, .confirming, .folderChanged, .refused, .notWatching] {
            #expect(!mode.offersAdoption(olderNotTracked: 2), "only while on and confirmed")
        }
        #expect(RetentionMode.confirming.showsDetails)
    }
}

struct LatestCaptureAgeTests {
    @Test func justNowForTheFirstMinute() {
        let created = Date(timeIntervalSince1970: 1_000_000)
        #expect(LatestCapture.isJustNow(created, now: created))
        #expect(LatestCapture.isJustNow(created, now: created.addingTimeInterval(59.9)))
        #expect(!LatestCapture.isJustNow(created, now: created.addingTimeInterval(60)))
        #expect(en(Copy.Latest.justNow) == "Just now")
    }
}

struct CopyTests {
    @Test func pluralsAndSizes() {
        #expect(en(Copy.Retention.wouldMove(1, "2 MB")) == "1 screenshot (2 MB) would go to the Trash now")
        #expect(en(Copy.Retention.wouldMove(12, "48 MB")) == "12 screenshots (48 MB) would go to the Trash now")
        #expect(en(Copy.Retention.skipped(1)) == "1 file here is not a screenshot and is never touched")
        #expect(en(Copy.Retention.skipped(3)) == "3 files here are not screenshots and are never touched")
        #expect(en(Copy.Retention.cleanUpTitle(2, "1 MB")) == "Move 2 screenshots (1 MB) to the Trash?")
        #expect(en(Copy.Retention.adoptButton(1, "1 MB")) == "Also clean up 1 older screenshot (1 MB)")
    }

    @Test func folderErrorsSayWhatIsWrong() {
        #expect(en(Copy.Capture.folderError(.notFound)) == "That folder does not exist.")
        #expect(en(Copy.Capture.folderError(.forbidden)) == "Choose a folder outside system locations and apps.")
    }

    @Test func statusItemLabelsAndAnnouncement() {
        #expect(en(StatusIconState.attention.accessibilityLabel) == "ClipShot, needs attention")
        #expect(en(Copy.screenshotCopied) == "Screenshot copied")
    }
}

struct TrailingActionLayoutTests {
    /// The button goes under the text once it takes more than 40% of the row, in every
    /// language alike, instead of below a fixed width that one translation passes and the
    /// next does not.
    @Test func stacksPastAShareOfTheRow() {
        #expect(!TrailingActionLayout.stacks(actionWidth: 80, rowWidth: 400))
        #expect(!TrailingActionLayout.stacks(actionWidth: 160, rowWidth: 400))
        #expect(TrailingActionLayout.stacks(actionWidth: 161, rowWidth: 400))
        #expect(TrailingActionLayout.stacks(actionWidth: 200, rowWidth: 300))
    }

    /// Stacked, the button starts in the text column past the icon, unless it is wider than
    /// that column; then at the row's edge rather than out of the row.
    @Test func stackedButtonStartsInTheTextColumn() {
        #expect(TrailingActionLayout.stackedActionX(actionWidth: 200, textX: 18, rowWidth: 400) == 18)
        #expect(TrailingActionLayout.stackedActionX(actionWidth: 382, textX: 18, rowWidth: 400) == 18)
        #expect(TrailingActionLayout.stackedActionX(actionWidth: 390, textX: 18, rowWidth: 400) == 0)
    }

    @MainActor
    @Test func laysOutSideBySideOrStacked() {
        func height(action: CGFloat) -> CGFloat {
            let view = NSHostingView(rootView: TrailingActionLayout {
                Text(verbatim: "Note")
                Color.clear.frame(width: action, height: 20)
            }
            .frame(width: 400))
            return view.fittingSize.height
        }
        #expect(height(action: 100) == 20, "beside the text, as tall as the button")
        #expect(height(action: 200) > 20 + Design.Spacing.s + 12, "under the text")
    }
}

/// The latest card's buttons: one row in every language, the primary taking what the two
/// square icon buttons leave, all three as tall as each other.
struct CardActionsLayoutTests {
    private func frames(primaryHeight: CGFloat) -> [CGRect] {
        CardActionsLayout.frames(
            width: 260, buttons: 3, side: 24, spacing: 4, primaryHeight: { _ in primaryHeight })
    }

    @Test func oneRowWithEqualSquareSecondaries() {
        let f = frames(primaryHeight: 22)
        #expect(f.count == 3)
        #expect(f.allSatisfy { $0.minY == 0 && $0.height == 24 }, "one row, one height")
        #expect(f[1].size == f[2].size && f[1].width == f[1].height, "two equal squares")
        #expect(f[0].width == 204, "the primary takes the rest: 260 - 2 * (24 + 4)")
        #expect(f[1].minX == f[0].maxX + 4 && f[2].minX == f[1].maxX + 4)
        #expect(f[2].maxX == 260, "flush with the card's trailing edge")
    }

    /// Square at the buttons' height, or at an icon button's width where the bezel needs more.
    @Test func sideIsTheLargerOfHeightAndIconWidth() {
        let primary = CGSize(width: 120, height: 22)
        #expect(CardActionsLayout.side(sizes: [primary, CGSize(width: 20, height: 22), CGSize(width: 21, height: 22)]) == 22)
        #expect(CardActionsLayout.side(sizes: [primary, CGSize(width: 25, height: 22), CGSize(width: 23, height: 22)]) == 25)
        #expect(CardActionsLayout.side(sizes: [CGSize(width: 300, height: 22), CGSize(width: 20, height: 22)]) == 22,
                "the primary's width never counts")
    }

    /// A label that wraps makes the row taller; it never stacks, and the secondaries keep
    /// their width and take the same height.
    @Test func aWrappedPrimaryKeepsTheRow() {
        let f = frames(primaryHeight: 38)
        #expect(f.allSatisfy { $0.minY == 0 && $0.height == 38 })
        #expect(f[1].width == 24 && f[2].width == 24)
        #expect(f[0].width == 204)
    }

    /// Real bordered buttons in the card's 260 pt: the row is one button tall with the
    /// English label, and the secondaries come out equal and square.
    @MainActor
    @Test func borderedButtonsShareOneRow() async throws {
        @MainActor final class Frames { var all: [Int: CGRect] = [:] }
        let frames = Frames()
        func tracked(_ index: Int, _ view: some View) -> some View {
            view.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.all[index] = $0 }
        }
        let row = CardActionsLayout {
            tracked(0, Button {} label: {
                Label { Text(verbatim: "Copy again") } icon: { Image(systemName: "doc.on.doc") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
            tracked(1, Button {} label: { Image(systemName: "folder").frame(maxWidth: .infinity, maxHeight: .infinity) })
            tracked(2, Button {} label: { Image(systemName: "trash").frame(maxWidth: .infinity, maxHeight: .infinity) })
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(width: 260)
        let view = NSHostingView(rootView: row)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        #expect(await eventually { await frames.all.count == 3 })
        let f = (0..<3).compactMap { frames.all[$0] }
        try #require(f.count == 3)
        #expect(Set(f.map(\.minY)).count == 1 && Set(f.map(\.height)).count == 1, "one row, one height")
        #expect(f[1].size == f[2].size, "\(f)")
        #expect(abs(f[1].width - f[1].height) < 0.5, "square")
        #expect(abs(f[2].maxX - f[0].minX - 260) < 0.5)
        #expect(view.fittingSize.height == f[0].height)
    }
}

/// The popover's status row (no app name): the three states, each with its one line.
struct HeaderStatusTests {
    @Test func stateTitleAndDetail() {
        let on = HeaderStatus.of(state: .copied, previewMode: .clipShot, showsThumbnailWait: false, attentions: 0)
        #expect(on.state == .idle && on.detail == .pasteAtOnce)
        #expect(en(on.title) == "Copying on")
        #expect(en(on.detailText) == "Screenshots are ready to paste at once")
        #expect(HeaderStatus.of(state: .idle, previewMode: .macOS, showsThumbnailWait: true, attentions: 0).detail == .thumbnailWait)
        #expect(HeaderStatus.of(state: .idle, previewMode: .macOS, showsThumbnailWait: false, attentions: 0).detail
            == .pasteAfterThumbnail)

        let paused = HeaderStatus.of(state: .paused, previewMode: .clipShot, showsThumbnailWait: false, attentions: 0)
        #expect(en(paused.title) == "Paused")
        #expect(en(paused.detailText) == "New screenshots are not copied")

        let attention = HeaderStatus.of(state: .attention, previewMode: .macOS, showsThumbnailWait: true, attentions: 2)
        #expect(attention.tint == .orange)
        #expect(en(attention.detailText) == "2 issues to fix")
        #expect(en(HeaderStatus(state: .attention, detail: .issues(1)).detailText) == "1 issue to fix")
    }
}
