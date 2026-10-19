import Foundation
import Testing
@testable import ClipShot

struct LogTests {
    @Test func logIsCreatedWith0600AndRollsByRename() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipshot-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("clipshot.log")
        let rolled = dir.appendingPathComponent("clipshot.log.1")
        let log = Log(fileURL: file, maxBytes: 1024)

        await log.info("hello")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(" INFO hello\n"))

        for _ in 0..<40 { await log.error(String(repeating: "x", count: 50)) }
        #expect(FileManager.default.fileExists(atPath: rolled.path))
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size < 1024)
        let rolledAttrs = try FileManager.default.attributesOfItem(atPath: rolled.path)
        #expect((rolledAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // A second roll replaces the existing .1.
        for _ in 0..<40 { await log.error(String(repeating: "y", count: 50)) }
        #expect(FileManager.default.fileExists(atPath: rolled.path))
    }
}
