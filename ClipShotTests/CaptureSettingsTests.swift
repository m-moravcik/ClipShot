import Foundation
import Testing
@testable import ClipShot

struct CaptureSettingsTests {
    let home = URL(fileURLWithPath: "/Users/t")

    private func make(_ initial: [String: Any] = [:]) -> (FakeScreencapturePreferences, CaptureSettings, URL) {
        let prefs = FakeScreencapturePreferences(initial)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backup = PrefsBackup(fileURL: dir.appendingPathComponent("backup.plist"))
        return (prefs, CaptureSettings(prefs: prefs, home: home, backup: backup), dir)
    }

    @Test func folderPrefersLocationScreenshotThenLocationThenDesktop() {
        let (prefs, settings, _) = make()
        #expect(settings.folder().path == "/Users/t/Desktop")
        prefs["location"] = "/Users/t/A"
        #expect(settings.folder().path == "/Users/t/A")
        prefs["location-screenshot"] = "/Users/t/B"
        #expect(settings.folder().path == "/Users/t/B")
    }

    @Test func tildeAndTrailingSlashPathsAreExpanded() {
        let (_, settings, _) = make(["location-screenshot": "~/Documents/"])
        #expect(settings.folder().path == "/Users/t/Documents")
    }

    @Test func destinationReadsTargetScreenshotBeforeTarget() {
        let (_, settings, _) = make(["target": "file", "target-screenshot": "clipboard"])
        #expect(settings.destination() == .clipboard)
        let (_, s2, _) = make(["target": "preview"])
        #expect(s2.destination() == .other("preview"))
    }

    @Test func destinationDefaultsToFileWhenKeysMissing() {
        let (_, settings, _) = make()
        #expect(settings.destination() == .file)
    }

    @Test func fixDestinationSetsBothKeysToFile() {
        let (prefs, settings, _) = make(["target": "clipboard", "target-screenshot": "preview"])
        settings.fixDestination()
        #expect(prefs["target"] as? String == "file")
        #expect(prefs["target-screenshot"] as? String == "file")
        #expect(settings.destination() == .file)
    }

    @Test func setFolderWritesAllThreeLocationKeys() throws {
        let (prefs, settings, dir) = make()
        try settings.setFolder(dir)
        let expected = dir.standardizedFileURL.path
        for key in ["location", "location-screenshot", "location-screenrecording"] {
            #expect(prefs[key] as? String == expected)
        }
    }

    @Test func setFolderNilRemovesKeys() throws {
        let (prefs, settings, _) = make([
            "location": "/x", "location-screenshot": "/x", "location-screenrecording": "/x",
        ])
        try settings.setFolder(nil)
        for key in ["location", "location-screenshot", "location-screenrecording"] {
            #expect(prefs[key] == nil)
        }
    }

    @Test func setFolderRejectsMissingFileAppBundleAndSystemPaths() throws {
        let (prefs, settings, dir) = make()
        #expect(throws: FolderValidation.notFound) {
            try settings.setFolder(dir.appendingPathComponent("nope"))
        }
        let file = dir.appendingPathComponent("f.txt")
        try Data("x".utf8).write(to: file)
        #expect(throws: FolderValidation.notDirectory) { try settings.setFolder(file) }
        #expect(throws: FolderValidation.forbidden) {
            try settings.setFolder(URL(fileURLWithPath: "/System/Library"))
        }
        #expect(throws: FolderValidation.forbidden) {
            try settings.setFolder(URL(fileURLWithPath: "/Applications/X.app/Contents"))
        }
        #expect(prefs["location"] == nil)
        #expect(settings.validate(dir) == .ok)
    }

    @Test func showThumbnailDefaultsTrueWhenKeyMissing() {
        let (prefs, settings, _) = make()
        #expect(settings.showThumbnail)
        settings.showThumbnail = false
        #expect(prefs["show-thumbnail"] as? Bool == false)
        #expect(!settings.showThumbnail)
    }

    @Test func readsSynchronizeFirst() {
        let (prefs, settings, _) = make()
        let before = prefs.synchronizeCount
        _ = settings.folder()
        #expect(prefs.synchronizeCount == before + 1)
        _ = settings.folder()
        #expect(prefs.synchronizeCount == before + 2)
    }
}
