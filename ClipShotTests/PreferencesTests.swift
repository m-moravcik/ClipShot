import Foundation
import Testing
@testable import ClipShot

@MainActor
struct PreferencesTests {
    private func withDefaults(_ body: (InMemoryPreferenceStore) -> Void) {
        body(InMemoryPreferenceStore())
    }

    @Test func freshInstallDefaults() {
        withDefaults { defaults in
            let p = Preferences(store: defaults)
            #expect(p.copyEnabled)
            #expect(p.retention == .default)
            #expect(!p.onboardingShown)
            #expect(p.launchAtLoginIntent == nil)
            #expect(p.lastRetention == nil)
            #expect(p.totals == Totals())
            #expect(!p.markupTipShown)
        }
    }

    @Test func valuesSurviveANewInstance() {
        withDefaults { defaults in
            let p = Preferences(store: defaults)
            p.copyEnabled = false
            p.retention = RetentionPolicy(enabled: true, days: 14, confirmed: nil)
            p.onboardingShown = true
            p.launchAtLoginIntent = true
            let result = RetentionResult(moved: 3, movedBytes: 4096, failed: 1, at: Date(timeIntervalSince1970: 1_000))
            p.lastRetention = result
            p.totals = Totals(copied: 5, freedBytes: 9_000_000_000, trashed: 2)
            p.markupTipShown = true

            let q = Preferences(store: defaults)
            #expect(!q.copyEnabled)
            #expect(q.retention.enabled && q.retention.days == 14)
            #expect(q.onboardingShown)
            #expect(q.launchAtLoginIntent == true)
            #expect(q.lastRetention == result)
            #expect(q.totals == Totals(copied: 5, freedBytes: 9_000_000_000, trashed: 2))
            #expect(q.markupTipShown)
        }
    }

    @Test func intentCanBeClearedAndKeysArePrefixed() {
        withDefaults { defaults in
            let p = Preferences(store: defaults)
            p.launchAtLoginIntent = false
            #expect(Preferences(store: defaults).launchAtLoginIntent == false)
            p.launchAtLoginIntent = nil
            #expect(Preferences(store: defaults).launchAtLoginIntent == nil)
            p.markupTipShown = true
            let keys = defaults.keys.filter { $0.hasPrefix("clipshot.") }
            #expect(keys.contains("clipshot.markupTipShown"))
            #expect(!keys.contains("clipshot.copySound"), "the copy sound setting is gone")
        }
    }

    @Test func corruptJSONFallsBackToDefault() {
        withDefaults { defaults in
            defaults.set(Data("nope".utf8), forKey: "clipshot.retention")
            defaults.set(Data("nope".utf8), forKey: "clipshot.totals")
            let p = Preferences(store: defaults)
            #expect(p.retention == .default)
            #expect(p.totals == Totals())
        }
    }
}
