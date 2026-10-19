import Foundation
import Testing
@testable import ClipShot

@MainActor
struct PreferencesTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "clipshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func freshInstallDefaults() {
        withDefaults { defaults in
            let p = Preferences(defaults: defaults)
            #expect(p.copyEnabled)
            #expect(!p.copySound)
            #expect(p.retention == .default)
            #expect(!p.onboardingShown)
            #expect(p.launchAtLoginIntent == nil)
            #expect(p.lastRetention == nil)
            #expect(p.totals == Totals())
            #expect(!p.firstCopyDone)
            #expect(!p.markupTipShown)
        }
    }

    @Test func valuesSurviveANewInstance() {
        withDefaults { defaults in
            let p = Preferences(defaults: defaults)
            p.copyEnabled = false
            p.copySound = true
            p.retention = RetentionPolicy(enabled: true, days: 14, confirmed: nil)
            p.onboardingShown = true
            p.launchAtLoginIntent = true
            let result = RetentionResult(moved: 3, movedBytes: 4096, failed: 1, at: Date(timeIntervalSince1970: 1_000))
            p.lastRetention = result
            p.totals = Totals(copied: 5, freedBytes: 9_000_000_000, trashed: 2)
            p.firstCopyDone = true
            p.markupTipShown = true

            let q = Preferences(defaults: defaults)
            #expect(!q.copyEnabled)
            #expect(q.copySound)
            #expect(q.retention.enabled && q.retention.days == 14)
            #expect(q.onboardingShown)
            #expect(q.launchAtLoginIntent == true)
            #expect(q.lastRetention == result)
            #expect(q.totals == Totals(copied: 5, freedBytes: 9_000_000_000, trashed: 2))
            #expect(q.firstCopyDone)
            #expect(q.markupTipShown)
        }
    }

    @Test func intentCanBeClearedAndKeysArePrefixed() {
        withDefaults { defaults in
            let p = Preferences(defaults: defaults)
            p.launchAtLoginIntent = false
            #expect(Preferences(defaults: defaults).launchAtLoginIntent == false)
            p.launchAtLoginIntent = nil
            #expect(Preferences(defaults: defaults).launchAtLoginIntent == nil)
            p.copySound = true
            let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("clipshot.") }
            #expect(keys.contains("clipshot.copySound"))
        }
    }

    @Test func corruptJSONFallsBackToDefault() {
        withDefaults { defaults in
            defaults.set(Data("nope".utf8), forKey: "clipshot.retention")
            defaults.set(Data("nope".utf8), forKey: "clipshot.totals")
            let p = Preferences(defaults: defaults)
            #expect(p.retention == .default)
            #expect(p.totals == Totals())
        }
    }
}
