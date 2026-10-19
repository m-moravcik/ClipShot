import Foundation
import Testing
@testable import ClipShot

struct PreviewModeTests {
    @Test func effectiveModeFollowsTheSystemThumbnail() {
        for stored in PreviewMode.allCases {
            #expect(PreviewMode.effective(stored: stored, showThumbnail: true) == .macOS)
        }
        #expect(PreviewMode.effective(stored: .clipShot, showThumbnail: false) == .clipShot)
        #expect(PreviewMode.effective(stored: .none, showThumbnail: false) == .none)
        #expect(PreviewMode.effective(stored: .macOS, showThumbnail: false) == .clipShot,
                "thumbnail turned off elsewhere: instant copy with ClipShot's preview")
        #expect(PreviewMode.macOS.showsSystemThumbnail)
        #expect(!PreviewMode.clipShot.showsSystemThumbnail && !PreviewMode.none.showsSystemThumbnail)
        #expect(PreviewMode.clipShot.showsOwnPreview && !PreviewMode.none.showsOwnPreview)
    }

    @MainActor @Test func defaultIsClipShotAndPersists() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        #expect(preferences.previewMode == .clipShot)
        #expect(!preferences.previewModeApplied)
        preferences.previewMode = .none
        preferences.previewModeApplied = true
        let reloaded = Preferences(store: store)
        #expect(reloaded.previewMode == .none)
        #expect(reloaded.previewModeApplied)
    }
}

@MainActor
struct PreviewModeModelTests {
    private func backup(_ h: ModelHarness) -> [String: Any]? {
        guard let data = try? Data(contentsOf: h.backupURL) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    @Test func previewModeFollowsSystemThumbnail() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .clipShot })

        // The user turns "Show Floating Thumbnail" on in Cmd+Shift+5 > Options.
        h.prefs["show-thumbnail"] = true
        #expect(await eventually { await h.model.previewMode == .macOS })
        try await Task.sleep(for: .milliseconds(400))
        #expect(h.prefs["show-thumbnail"] as? Bool == true, "never written back")
        #expect(h.model.previewMode == .macOS)
        #expect(h.preferences.previewMode == .clipShot, "the choice is kept, only overridden")
        #expect(backup(h) == nil, "nothing was written")
    }

    @Test func firstStartAppliesTheDefaultOnce() async throws {
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        #expect(h.model.previewMode == .clipShot, "the default, before anything is read")
        #expect(h.prefs["show-thumbnail"] == nil)
        #expect(await h.start())
        #expect(await eventually { h.prefs["show-thumbnail"] as? Bool == false })
        #expect(h.preferences.previewModeApplied)
        #expect(h.model.previewMode == .clipShot)
        let saved = try #require(backup(h))
        #expect(saved["show-thumbnail"] == nil, "the backup holds the original: no key")

        // Later, the system pref turned back on is followed, not fought.
        h.prefs["show-thumbnail"] = true
        h.model.stopWatching()
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .macOS })
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
    }

    @Test func choosingClipShotTurnsThumbnailOffThroughBackup() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .macOS })

        await h.model.setPreviewMode(.clipShot)
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(h.model.previewMode == .clipShot)
        #expect(backup(h)?["show-thumbnail"] as? Bool == true, "backed up before the first write")

        await h.model.setPreviewMode(.none)
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(h.model.previewMode == .none)

        await h.model.setPreviewMode(.macOS)
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
        #expect(h.model.previewMode == .macOS)
        #expect(backup(h)?["show-thumbnail"] as? Bool == true, "the backup is written once")
    }

    @Test func restoreBringsBackOriginalThumbnail() async throws {
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        #expect(await eventually { h.prefs["show-thumbnail"] as? Bool == false })
        #expect(await h.model.restorePreviousSettings())
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
        #expect(await eventually { await h.model.previewMode == .macOS })
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.prefs["show-thumbnail"] as? Bool == true, "restore is not undone by the default")
    }

    @Test func previewsShowOnlyInClipShotMode() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        h.preferences.previewMode = .none
        #expect(await h.start())
        try h.shoot("Screenshot 1.png", size: 20)
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.model.previews.items.isEmpty)

        await h.model.setPreviewMode(.clipShot)
        try h.shoot("Screenshot 2.png", size: 21)
        #expect(await eventually { await h.model.previews.visible.count == 1 })
        #expect(h.model.previews.visible.first?.file.url.lastPathComponent == "Screenshot 2.png")
        #expect(h.model.previews.visible.first?.image != nil)

        await h.model.setPreviewMode(.none)
        #expect(await eventually { await h.model.previews.items.isEmpty })
    }
}
