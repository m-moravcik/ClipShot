import Foundation
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
        #expect(RetentionSummary.of(policy: policy, refusal: nil) == .keeps(days: 30))
        #expect(RetentionSummary.of(policy: policy, refusal: .notConfirmed) == .paused)
        #expect(RetentionSummary.of(policy: policy, refusal: .noTrash) == .offForFolder)
        #expect(RetentionSummary.of(policy: policy, refusal: .systemOrBroad) == .offForFolder)
        #expect(en(RetentionSummary.offForFolder.title) == "Retention is off for this folder")
        #expect(en(RetentionSummary.paused.title) == "Retention is paused")
        #expect(en(RetentionSummary.keeps(days: 30).title) == "Keeps 30 days")
        #expect(en(RetentionSummary.keeps(days: 1).title) == "Keeps 1 day")
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
