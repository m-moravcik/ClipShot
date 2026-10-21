import Foundation
import Testing
@testable import ClipShot

/// The real `clipshot` binary (Contents/Helpers/clipshot) against the app's control socket,
/// answered by the app's model on a throwaway folder and ledger (`ModelHarness`): what a
/// terminal user gets, across the process boundary, for the commands that change state.
@MainActor
struct CLIBinaryModelTests {
    private struct Run: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static var binary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clipshot") }

    /// Runs the binary off the main actor: the model answers the socket on it.
    private func run(_ arguments: [String], support: URL) async throws -> Run {
        let binary = Self.binary
        return try await Task.detached {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment[ControlProtocol.supportDirectoryEnvironmentKey] = support.path
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(
                status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self))
        }.value
    }

    private func canon(_ url: URL) -> String { FolderGuard.canonicalPath(url) }

    /// Only marked screenshots ClipShot tracks are listed and copied; an untracked marked
    /// file, an unmarked download and a tracked screenshot replaced at its path are refused,
    /// and the clipboard is left alone for each.
    @Test func copyAndLatestOfferOnlyTrackedMarkedScreenshots() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        let older = try RT.shot("older.png", in: h.folder, age: 300, now: now)
        let newer = try RT.shot("newer.png", in: h.folder, age: 200, now: now)
        for url in [older, newer] { await h.ledger.record(RT.file(url)) }
        // Old enough not to be copied (and so tracked) when watching starts.
        let untracked = try RT.shot("untracked.png", in: h.folder, age: 120, now: now)
        let download = try RT.shot("download.png", in: h.folder, age: 120, now: now, marker: .none, quarantine: true)
        #expect(await h.start())
        let (server, support) = try h.controlServer()
        defer { server.stop() }

        let latest = try await run(["latest", "-n", "10"], support: support)
        #expect(latest.status == 0, "\(latest.stderr)")
        #expect(latest.stdout == [newer, older].map { canon($0) + "\n" }.joined())

        let copy = try await run(["copy"], support: support)
        #expect(copy.status == 0 && copy.stdout == "copied: \(canon(newer))\n", "\(copy.stderr)")
        #expect(h.pasteboard.writes.count == 1)

        for url in [untracked, download] {
            let refused = try await run(["copy", url.path, "--json"], support: support)
            #expect(refused.status == 1, "\(url.lastPathComponent)")
            #expect(refused.stdout.contains(#""code":"refusedFile""#), "\(refused.stdout)")
            #expect(refused.stderr.contains("is not a screenshot ClipShot saw being taken"))
        }

        // A marked file renamed over the tracked newest one is another file at that path.
        let replacement = try RT.shot("replacement.png", in: h.folder, age: 120, now: now)
        #expect(rename(replacement.path, newer.path) == 0)
        let afterReplace = try await run(["latest", "-n", "10"], support: support)
        #expect(afterReplace.status == 0 && afterReplace.stdout == canon(older) + "\n", "\(afterReplace.stdout)")
        let replaced = try await run(["copy", newer.path], support: support)
        #expect(replaced.status == 1, "\(replaced.stdout)")
        let latestCopy = try await run(["copy"], support: support)
        #expect(latestCopy.stdout == "copied: \(canon(older))\n", "\(latestCopy.stderr)")
        #expect(h.pasteboard.writes.count == 2)
    }

    /// `pause` and `resume` are the Copy to clipboard switch, with Peg's moments, and
    /// `status` reports who paused.
    @Test func pauseResumeAndStatusThroughTheBinary() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, support) = try h.controlServer()
        defer { server.stop() }

        let pause = try await run(["pause"], support: support)
        #expect(pause.status == 0 && pause.stdout == "copying paused\n", "\(pause.stderr)")
        #expect(!h.preferences.copyEnabled && h.model.flashMoment == .pause)
        let status = try await run(["status", "--json"], support: support)
        let decoded = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(status.stdout.utf8))
        #expect(decoded.running && !decoded.copying && decoded.pausedBy == .manual)
        let again = try await run(["pause"], support: support)
        #expect(again.status == 0 && again.stdout.contains("already"), "\(again.stdout)")

        let resume = try await run(["resume"], support: support)
        #expect(resume.status == 0 && resume.stdout == "copying resumed\n", "\(resume.stderr)")
        #expect(h.preferences.copyEnabled && h.model.flashMoment == .resume)
    }
}
