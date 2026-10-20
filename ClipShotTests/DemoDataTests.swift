import Foundation
import Testing
@testable import ClipShot

/// The screenshot harness's demo data (Debug only): the pictures in the README must look like
/// what a user of each language sees, and never show something impossible.
@MainActor
struct DemoDataTests {
    @Test func launchArgumentsBecomeBooleansOnlyWhenSpelledAsBooleans() {
        #expect(DemoPreferenceStore.coerced("YES") as? Bool == true)
        #expect(DemoPreferenceStore.coerced("true") as? Bool == true)
        #expect(DemoPreferenceStore.coerced("NO") as? Bool == false)
        #expect(DemoPreferenceStore.coerced("false") as? Bool == false)
        // A number stays a number: `-clipshot.retentionDays 1` is a period, not "on".
        #expect(DemoPreferenceStore.coerced("1") as? String == "1")
        #expect(DemoPreferenceStore.coerced("0") as? String == "0")
        #expect(DemoPreferenceStore.coerced(nil) == nil)
    }

    @Test func englishScreenshotNamesUseTheTwelveHourClock() {
        #expect(DemoContent.screenshotTime("09.41.12", language: "en") == "at 9.41.12\u{202F}AM")
        #expect(DemoContent.screenshotTime("14.10.05", language: "en") == "at 2.10.05\u{202F}PM")
        #expect(DemoContent.screenshotTime("00.05.00", language: "en") == "at 12.05.00\u{202F}AM")
        #expect(DemoContent.screenshotTime("12.30.00", language: "en") == "at 12.30.00\u{202F}PM")
        #expect(DemoContent.screenshotTime("09.41.12", language: "de") == "um 09.41.12")
        #expect(DemoContent.screenshotTime("09.41.12", language: "sk") == "o 9.41.12")
    }

    @Test func picturesShowTheLastCleanupTodayAtWhateverTimeTheyAreRendered() {
        let cleanup = DemoContent.lastCleanup(now: DemoContent.renderNow)
        #expect(Calendar.current.isDate(cleanup, inSameDayAs: DemoContent.renderNow))
        #expect(cleanup < DemoContent.renderNow)
        #expect(String(localized: RetentionSummary.lastCleanup(
            RetentionResult(moved: 12, movedBytes: 1, failed: 0, at: cleanup), now: DemoContent.renderNow))
            .hasPrefix("Last cleanup today at"))
    }

    @Test func lastCleanupIsAlwaysInThePast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Bratislava"))
        func at(_ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: hour, minute: minute)))
        }
        // Late enough: today at 09:12.
        let afternoon = try at(15, 0), morning = try at(9, 12)
        #expect(DemoContent.lastCleanup(now: afternoon, calendar: calendar) == morning)
        // Before 09:22 it would be "in a few minutes" or "just now": yesterday at 09:12.
        for now in [try at(0, 5), try at(9, 0), try at(9, 15)] {
            let cleanup = DemoContent.lastCleanup(now: now, calendar: calendar)
            #expect(cleanup < now)
            #expect(calendar.component(.day, from: cleanup) == 19)
            #expect(calendar.component(.hour, from: cleanup) == 9 && calendar.component(.minute, from: cleanup) == 12)
        }
    }
}
