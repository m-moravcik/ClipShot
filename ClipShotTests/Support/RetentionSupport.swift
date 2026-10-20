import Foundation
import Synchronization
@testable import ClipShot

/// Moves files into its own temp "trash" directory with rename(2). Never touches the real Trash.
final class FakeTrasher: Trashing {
    private struct State: Sendable {
        var failing: Set<String>
        var trashed: [String] = []
    }

    let trashDir: URL
    private let state: Mutex<State>

    /// `failing` names throw once, then succeed.
    init(failing: Set<String> = []) throws {
        trashDir = try Fixtures.makeDir()
        state = Mutex(State(failing: failing))
    }

    var trashed: [String] { state.withLock { $0.trashed } }

    @discardableResult
    func trash(_ url: URL) throws -> URL? {
        let name = url.lastPathComponent
        let fail = state.withLock { $0.failing.remove(name) != nil }
        if fail { throw CocoaError(.fileWriteUnknown) }
        let dest = trashDir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        guard rename(url.path, dest.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        state.withLock { $0.trashed.append(name) }
        return dest
    }
}

enum RT {
    static let day: TimeInterval = 86_400
    static let hasTrash: FolderGuard.TrashLookup = { _ in true }
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let png = Fixtures.pngImage()

    /// Whole seconds, so creation dates set through the file system compare exactly.
    static func now() -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }

    @discardableResult
    static func shot(
        _ name: String, in dir: URL, age: TimeInterval, now: Date,
        marker: Fixtures.Marker = .true, captureType: Bool = true,
        quarantine: Bool = false, whereFroms: Bool = false
    ) throws -> URL {
        try Fixtures.write(
            named: name, contents: png, in: dir, marker: marker, captureType: captureType,
            quarantine: quarantine, whereFroms: whereFroms, created: now.addingTimeInterval(-age))
    }

    static func file(_ url: URL) -> CaptureFile { CaptureFile.inspect(url)! }

    static func entry(_ url: URL) -> LedgerEntry { LedgerEntry(file(url)) }

    static func testLog() throws -> Log {
        Log(fileURL: try Fixtures.makeDir().appendingPathComponent("test.log"))
    }

    static func ledger() throws -> ScreenshotLedger {
        ScreenshotLedger(fileURL: try Fixtures.makeDir().appendingPathComponent("ledger.json"), log: try testLog())
    }

    static func policy(_ dir: URL, days: Int = 30, enabled: Bool = true) -> RetentionPolicy {
        RetentionPolicy(enabled: enabled, days: days, confirmed: ConfirmedFolder.of(dir))
    }

    static func scan(
        _ dir: URL, policy: RetentionPolicy, ledger: [LedgerEntry], now: Date
    ) -> Result<RetentionScan, Refusal> {
        RetentionScanner.scan(folder: dir, policy: policy, ledger: ledger, now: now, home: home, hasTrash: hasTrash)
    }

    static func runner(_ trasher: FakeTrasher, _ ledger: ScreenshotLedger) throws -> RetentionRunner {
        RetentionRunner(trasher: trasher, ledger: ledger, log: try testLog())
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }
}

extension Result {
    var success: Success? { if case .success(let value) = self { value } else { nil } }
}
