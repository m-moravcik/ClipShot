import Foundation
import Testing
@testable import ClipShot

struct PrefsBackupTests {
    private func backupURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-backup-\(UUID().uuidString).plist")
    }

    @Test func backupIsWrittenOnceAndRestores() {
        let backup = PrefsBackup(fileURL: backupURL())
        backup.saveOnce(["location": "/a", "show-thumbnail": false])
        backup.saveOnce(["location": "/changed"])
        let prefs = FakeScreencapturePreferences(["location": "/changed"])
        #expect(backup.restore(into: prefs))
        #expect(prefs["location"] as? String == "/a")
        #expect(prefs["show-thumbnail"] as? Bool == false)
    }

    @Test func restoreDeletesKeysAbsentFromBackup() {
        let backup = PrefsBackup(fileURL: backupURL())
        backup.saveOnce(["location": "/a"])
        let prefs = FakeScreencapturePreferences([
            "location": "/b", "target": "clipboard", "target-screenshot": "clipboard",
            "location-screenshot": "/b", "unrelated": 1,
        ])
        #expect(backup.restore(into: prefs))
        #expect(prefs["location"] as? String == "/a")
        #expect(prefs["target"] == nil)
        #expect(prefs["target-screenshot"] == nil)
        #expect(prefs["location-screenshot"] == nil)
        #expect(prefs["unrelated"] as? Int == 1)
    }

    @Test func restoreWithoutBackupReturnsFalse() {
        let backup = PrefsBackup(fileURL: backupURL())
        #expect(!backup.restore(into: FakeScreencapturePreferences()))
    }
}
