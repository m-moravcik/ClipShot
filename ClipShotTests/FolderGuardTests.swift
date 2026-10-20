import Foundation
import Testing
@testable import ClipShot

struct FolderGuardTests {
    private func refusal(_ path: String, home: URL = RT.home) -> Refusal? {
        FolderGuard.refusal(for: URL(fileURLWithPath: path), home: home, hasTrash: RT.hasTrash)
    }

    @Test func refusesBroadFoldersIncludingSymlinkToHomeAndTrailingSlash() throws {
        let home = RT.home.path
        let broad = [
            "/", "/Users", "/Users/", "/Users/Shared", home, home + "/", home + "/.",
            home + "/Library", home + "/Library/", home + "/.Trash",
            "/System", "/System/Library", "/Library", "/Library/Caches", "/Applications",
            "/Applications/Safari.app/Contents", "/Volumes", "/Volumes/", "/Volumes/External",
            "/private", "/private/var", "/private/var/folders", "/tmp", "/usr/bin",
        ]
        for path in broad {
            #expect(refusal(path) == .systemOrBroad, "\(path)")
        }

        let links = try Fixtures.makeDir()
        let toHome = links.appendingPathComponent("home")
        try FileManager.default.createSymbolicLink(at: toHome, withDestinationURL: RT.home)
        let toRoot = links.appendingPathComponent("root")
        try FileManager.default.createSymbolicLink(atPath: toRoot.path, withDestinationPath: "/")
        #expect(refusal(toHome.path) == .systemOrBroad)
        #expect(refusal(toHome.path + "/") == .systemOrBroad)
        #expect(refusal(toRoot.path) == .systemOrBroad)
        #expect(refusal(toHome.path + "/Library") == .systemOrBroad)

        #expect(refusal(home + "/Desktop") == nil)
        #expect(refusal(home + "/Pictures/Screenshots") == nil)
        #expect(refusal(try Fixtures.makeDir().path) == nil)
    }

    @Test func injectedHomeAncestorsAndLibraryAreRefused() throws {
        let root = try Fixtures.makeDir()
        let home = root.appendingPathComponent("people/me", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Shots"), withIntermediateDirectories: true)
        #expect(refusal(root.path, home: home) == .systemOrBroad)
        #expect(refusal(root.appendingPathComponent("people").path, home: home) == .systemOrBroad)
        #expect(refusal(home.path, home: home) == .systemOrBroad)
        #expect(refusal(home.appendingPathComponent("Library").path, home: home) == .systemOrBroad)
        #expect(refusal(home.appendingPathComponent("Shots").path, home: home) == nil)
    }

    @Test func volumeWithoutTrashIsRefused() throws {
        let dir = try Fixtures.makeDir()
        let asked = URLBox()
        let noTrash: FolderGuard.TrashLookup = { url in asked.set(url); return false }
        #expect(FolderGuard.refusal(for: dir, home: RT.home, hasTrash: noTrash) == .noTrash)
        #expect(asked.value?.path == ConfirmedFolder.of(dir)?.path)

        let now = RT.now()
        try RT.shot("a.png", in: dir, age: 40 * RT.day, now: now)
        let result = RetentionScanner.scan(
            folder: dir, policy: RT.policy(dir), ledger: [RT.entry(dir.appendingPathComponent("a.png"))],
            now: now, home: RT.home, hasTrash: noTrash)
        #expect(result == .failure(.noTrash))
    }

    @Test func broadFolderFailsTheScanBeforeAnything() throws {
        let result = RetentionScanner.scan(
            folder: RT.home, policy: RT.policy(RT.home), ledger: [], now: RT.now(), home: RT.home, hasTrash: RT.hasTrash)
        #expect(result == .failure(.systemOrBroad))
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var value: URL? { lock.withLock { stored } }
    func set(_ url: URL) { lock.withLock { stored = url } }
}
