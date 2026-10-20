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
        #expect(await h.statusRead())
        #expect(h.prefs["show-thumbnail"] as? Bool == true, "never written back")
        #expect(h.model.previewMode == .macOS)
        #expect(h.preferences.previewMode == .clipShot, "the choice is kept, only overridden")
        #expect(backup(h) == nil, "nothing was written")
    }

    @Test func modeIsUnknownUntilTheFirstRead() async throws {
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(h.model.showThumbnail == nil)
        #expect(!h.model.previewModeKnown)
        #expect(!h.model.showsPreviewOffer && !h.model.showsThumbnailWait, "no macOS-mode UI before a read")
        #expect(h.model.previewMode == .clipShot, "the choice, until the system value is known")
        #expect(await h.start())
        #expect(await eventually { await h.model.previewModeKnown })
        #expect(h.model.previewMode == .macOS)
    }

    @Test func upgradeNeverWritesThumbnail() async throws {
        // Onboarding done before Preview modes existed; the macOS thumbnail is on (no key).
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        #expect(await h.start())
        #expect(await eventually { await h.model.showsPreviewOffer })
        #expect(await h.statusRead())
        #expect(h.prefs["show-thumbnail"] == nil, "nothing written")
        #expect(backup(h) == nil)
        #expect(h.model.previewMode == .macOS)
        #expect(!h.preferences.previewModeApplied)
        #expect(!h.model.showsThumbnailWait, "the offer row says it; the header line waits")

        // No preview while the macOS thumbnail is on.
        let events = h.model.copyEventsHandled
        try h.shoot("Screenshot 1.png")
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        #expect(await h.copySettled(after: events))
        #expect(h.model.previews.items.isEmpty)
    }

    @Test func offerSwitchUsesBackupOnce() async throws {
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        #expect(await eventually { await h.model.showsPreviewOffer })

        await h.model.acceptPreviewOffer()
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(backup(h)?["show-thumbnail"] as? Bool == true, "the original, saved before the write")
        #expect(h.preferences.previewModeApplied)
        #expect(h.model.previewMode == .clipShot)
        #expect(!h.model.showsPreviewOffer)

        // A later write keeps the first backup.
        await h.model.setPreviewMode(.macOS)
        await h.model.setPreviewMode(.clipShot)
        #expect(backup(h)?["show-thumbnail"] as? Bool == true)
    }

    @Test func offerDismissIsPermanent() async throws {
        let h = try ModelHarness(previewModeApplied: false)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        #expect(await eventually { await h.model.showsPreviewOffer })

        h.model.dismissPreviewOffer()
        #expect(!h.model.showsPreviewOffer)
        #expect(h.preferences.previewModeApplied)
        #expect(h.model.showsThumbnailWait, "macOS mode keeps its quiet header line")
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
        #expect(backup(h) == nil)

        h.model.stopWatching()
        #expect(await h.start())
        #expect(await eventually { await h.model.previewModeKnown })
        #expect(await h.statusRead())
        #expect(!h.model.showsPreviewOffer, "never offered again")
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
    }

    @Test func onboardingStartAppliesClipShotMode() async throws {
        let h = try ModelHarness(onboardingShown: false, previewModeApplied: false)
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        var tour = WelcomeTour(step: .folder)
        #expect(tour.primary(h.model) == .startCopying)
        tour.advance(h.model)
        #expect(h.model.previewMode == .clipShot, "the tour's Try it never shows the macOS text")
        #expect(await eventually { h.prefs["show-thumbnail"] as? Bool == false })
        #expect(await eventually { await h.preferences.previewModeApplied })
        #expect(backup(h)?["show-thumbnail"] as? Bool == true)
        #expect(h.model.previewMode == .clipShot)
        #expect(!h.model.showsPreviewOffer)
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
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        await h.model.setPreviewMode(.clipShot)
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(await h.model.restorePreviousSettings())
        #expect(h.prefs["show-thumbnail"] as? Bool == true)
        #expect(await eventually { await h.model.previewMode == .macOS })
        #expect(await h.statusRead())
        #expect(h.prefs["show-thumbnail"] as? Bool == true, "restore is not undone")
    }

    @Test func previewsShowOnlyInClipShotMode() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = false
        h.preferences.previewMode = .none
        #expect(await h.start())
        let events = h.model.copyEventsHandled
        try h.shoot("Screenshot 1.png", size: 20)
        #expect(await eventually { await h.pasteboard.writes.count == 1 })
        #expect(await h.copySettled(after: events))
        #expect(h.model.previews.items.isEmpty)

        await h.model.setPreviewMode(.clipShot)
        try h.shoot("Screenshot 2.png", size: 21)
        #expect(await eventually { await h.model.previews.visible.count == 1 })
        #expect(h.model.previews.visible.first?.file.url.lastPathComponent == "Screenshot 2.png")
        #expect(h.model.previews.visible.first?.image != nil)

        await h.model.setPreviewMode(.none)
        #expect(await eventually { await h.model.previews.items.isEmpty })
    }

    /// C-2: when the one-time backup cannot be written, nothing changes, the picker keeps
    /// the mode in effect (it never flips back later on its own), and Settings says why.
    @Test func aFailedBackupChangesNothingAndSaysSo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        h.prefs["show-thumbnail"] = true
        #expect(await h.start())
        #expect(await eventually { await h.model.previewMode == .macOS })
        // The backup goes next to the home folder's files; a read-only home refuses it.
        #expect(chmod(h.home.path, 0o555) == 0)
        defer { chmod(h.home.path, 0o755) }

        await h.model.setPreviewMode(.clipShot)
        #expect(h.prefs["show-thumbnail"] as? Bool == true, "nothing written")
        #expect(h.model.previewMode == .macOS, "the picker shows what is in effect")
        #expect(h.model.settingsBackupFailed)
        await h.model.fixDestination()
        #expect(h.model.settingsBackupFailed)
        await #expect(throws: FolderValidation.backupFailed) { try await h.model.setFolder(h.folder) }
        #expect(h.model.folderError == .backupFailed)

        chmod(h.home.path, 0o755)
        await h.model.setPreviewMode(.clipShot)
        #expect(h.prefs["show-thumbnail"] as? Bool == false)
        #expect(!h.model.settingsBackupFailed, "a write that succeeds clears the note")
        #expect(h.model.previewMode == .clipShot)
    }
}

