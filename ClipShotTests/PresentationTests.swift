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

/// The latest card's actions: content-sized pills, leading, that wrap onto a second line
/// rather than stretching or truncating.
struct FlowLayoutTests {
    @Test func linesBreakOnlyWhenTheNextOneDoesNotFit() {
        #expect(FlowLayout.lines(widths: [80, 90, 30], width: 260, spacing: 4) == [[0, 1, 2]])
        #expect(FlowLayout.lines(widths: [80, 90, 30], width: 208, spacing: 4) == [[0, 1, 2]], "exactly full")
        #expect(FlowLayout.lines(widths: [80, 90, 30], width: 207, spacing: 4) == [[0, 1], [2]])
        #expect(FlowLayout.lines(widths: [200, 150, 30], width: 260, spacing: 4) == [[0], [1, 2]])
        #expect(FlowLayout.lines(widths: [300], width: 260, spacing: 4) == [[0]], "never an empty line")
        #expect(FlowLayout.lines(widths: [], width: 260, spacing: 4).isEmpty)
    }

    /// The card's three pills, laid out `width` wide; their frames and the row's height.
    /// `reveal` nil: Show in Finder as a symbol only, as the card has it.
    @MainActor
    private func layOut(
        copy: String, reveal: String?, width: CGFloat, direction: LayoutDirection = .leftToRight
    ) async throws -> (frames: [CGRect], ideal: [CGSize], height: CGFloat) {
        @MainActor final class Frames { var all: [Int: CGRect] = [:] }
        let frames = Frames()
        func tracked(_ index: Int, _ view: some View) -> some View {
            view.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.all[index] = $0 }
        }
        func pill(_ symbol: String, _ title: String?) -> some View {
            Button {} label: {
                PillLabel(symbol: symbol, title: title.map { LocalizedStringResource(stringLiteral: $0) })
            }
            .buttonStyle(PillButtonStyle())
        }
        let pills = [pill("doc.on.doc", copy), pill("folder", reveal), pill("trash", nil)]
        let ideal = pills.map { NSHostingView(rootView: $0).fittingSize }
        let row = FlowLayout(spacing: 4, lineSpacing: 4) {
            tracked(0, pills[0])
            tracked(1, pills[1])
            tracked(2, pills[2])
        }
        .frame(width: width)
        .environment(\.layoutDirection, direction)
        let view = NSHostingView(rootView: row)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        #expect(await eventually { await frames.all.count == 3 })
        let f = (0..<3).compactMap { frames.all[$0] }
        try #require(f.count == 3)
        return (f, ideal, view.fittingSize.height)
    }

    /// The card as it is, in its 260 pt: one line, leading, each pill at its own width, and
    /// the symbol-only pills as tall as Copy again.
    @MainActor
    @Test func pillsAreContentSizedOnOneLine() async throws {
        let (f, ideal, height) = try await layOut(copy: "Copy again", reveal: nil, width: 260)
        #expect(Set(f.map(\.minY)).count == 1, "one line: \(f)")
        #expect(f[0].minX == 0, "leading")
        for i in 0..<3 { #expect(abs(f[i].width - ideal[i].width) < 0.5, "pill \(i) at its own width: \(f[i]) vs \(ideal[i])") }
        #expect(f[2].height == f[0].height && f[1].height == f[0].height, "one height: \(f)")
        #expect(f[2].width < f[2].height + 12 && f[1].width == f[2].width, "the symbol-only pills stay small: \(f)")
        #expect(height == f[0].height)
    }

    /// Doubled German, as pseudo-de: the row wraps; every pill keeps its whole width.
    @MainActor
    @Test func aLongRowWrapsInsteadOfTruncating() async throws {
        let (f, ideal, height) = try await layOut(
            copy: "Erneut kopieren Erneut kopieren", reveal: "Im Finder zeigen Im Finder zeigen", width: 260)
        #expect(f[1].minY > f[0].maxY, "Show in Finder on the next line: \(f)")
        #expect(f[1].minX == 0 && f[2].minY == f[1].minY, "it leads the second line, Trash beside it")
        for i in 0..<3 { #expect(abs(f[i].width - ideal[i].width) < 0.5, "pill \(i) not truncated: \(f[i]) vs \(ideal[i])") }
        #expect(height > 2 * f[0].height)
    }

    /// The longest Copy again of the six languages fits one line with the two symbol pills.
    @MainActor
    @Test func everyLanguageFitsOneLine() async throws {
        var titles: [String] = []
        for id in ["en", "sk", "cs", "de", "es", "fr"] {
            for key in [Copy.Action.copyAgain, Copy.Preview.copy] {
                var resource = key
                resource.locale = Locale(identifier: id)
                titles.append(String(localized: resource))
            }
        }
        let widest = try #require(titles.max { $0.count < $1.count })
        let (f, _, _) = try await layOut(copy: widest, reveal: nil, width: 260)
        #expect(Set(f.map(\.minY)).count == 1, "\(widest): \(f)")
        #expect(f[2].maxX <= 260)
    }

    /// Right to left, the row mirrors: the first pill at the right-hand edge.
    @MainActor
    @Test func mirrorsRightToLeft() async throws {
        let (f, _, _) = try await layOut(copy: "Copy again", reveal: nil, width: 260, direction: .rightToLeft)
        #expect(f[0].minX > f[1].maxX && f[1].minX > f[2].maxX, "\(f)")
        #expect(abs(f[0].maxX - 260) < 0.5)
    }
}

/// The card's age in words, and "Just now" for the first minute.
struct LatestAgeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let en = Locale(identifier: "en_US")

    @Test func naturalRelativeAge() {
        #expect(LatestCapture.isJustNow(now.addingTimeInterval(-59), now: now))
        #expect(!LatestCapture.isJustNow(now.addingTimeInterval(-60), now: now))
        #expect(LatestCapture.relativeAge(now.addingTimeInterval(-(41 * 60 + 24)), now: now, locale: en) == "41 minutes ago")
        #expect(LatestCapture.relativeAge(now.addingTimeInterval(-2 * 3_600), now: now, locale: en) == "2 hours ago")
        #expect(LatestCapture.relativeAge(now.addingTimeInterval(-26 * 3_600), now: now, locale: en) == "Yesterday")
        #expect(LatestCapture.relativeAge(now.addingTimeInterval(5), now: now, locale: en) == "Now", "never in the future")
    }

    /// Every language of the app gets the age in its own words, never seconds.
    @Test func everyLanguageSaysItsOwnWords() {
        for id in ["sk", "cs", "de", "es", "fr"] {
            let text = LatestCapture.relativeAge(now.addingTimeInterval(-41 * 60), now: now, locale: Locale(identifier: id))
            #expect(text.contains("41") && !text.contains("ago"), "\(id): \(text)")
        }
    }

    @Test func scheduleWakesAtTheEndOfJustNowThenEveryMinute() {
        let switchAt = now.addingTimeInterval(30)
        let entries = Array(AgeSchedule(switchAt: switchAt).entries(from: now, mode: .normal).prefix(3))
        #expect(entries == [now, switchAt, switchAt.addingTimeInterval(60)])
    }
}

/// The strip's keyboard: Space and Return open Markup from the thumbnail only, never while
/// one of its buttons has focus (that button takes the key).
@MainActor
struct RecentItemKeyTests {
    @Test func onlyTheThumbnailOpensMarkup() {
        #expect(RecentItem.keyOpensMarkup(focus: .thumbnail))
        #expect(!RecentItem.keyOpensMarkup(focus: .copy))
        #expect(!RecentItem.keyOpensMarkup(focus: .reveal))
        #expect(!RecentItem.keyOpensMarkup(focus: .trash))
        #expect(!RecentItem.keyOpensMarkup(focus: nil))
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

/// The strip's hover pills (Task 12f leftover): three fit inside the 64 pt thumbnail with
/// at least 4 pt on each side, and each still takes clicks over at least 20 x 20 pt.
@MainActor
struct RecentItemLayoutTests {
    private func compactPill(_ symbol: String) -> CGSize {
        NSHostingView(rootView: Button {} label: { PillLabel(symbol: symbol) }
            .buttonStyle(PillButtonStyle(compact: true, onImage: true))).fittingSize
    }

    @Test func threePillsKeepAMarginInsideTheThumbnail() {
        let widths = ["doc.on.doc", "checkmark", "folder", "trash"].map { compactPill($0).width }
        let widest = widths.max() ?? 0
        let bar = widest * 3 + RecentItem.barSpacing * 2
        #expect((Design.Layout.thumbnailSize.width - bar) / 2 >= 4, "bar \(bar) pt in \(Design.Layout.thumbnailSize.width)")
    }

    @Test func eachPillStillTakesTwentyPointClicks() {
        let size = compactPill("trash")
        let outset = PillButtonStyle.compactHitOutset * 2
        #expect(size.width + outset >= 20)
        #expect(size.height + outset >= 20)
    }
}
