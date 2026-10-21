import Foundation
import Testing
@testable import ClipShot

/// The real `clipshot`, as built into the app at Contents/Helpers/clipshot (the test host is
/// the app). Every run gets `CLIPSHOT_SUPPORT_DIR` pointing at a fresh folder, and only
/// commands that never read the real screenshot settings or folder are run: version, help,
/// usage errors, commands that need the app (which is not running there), and a round trip
/// with a server in this process.
struct CLIBinaryTests {
    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static var binary: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clipshot") }

    private func run(_ arguments: [String], support: URL, domain: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment[ControlProtocol.supportDirectoryEnvironmentKey] = support.path
        if let domain { environment[ControlProtocol.defaultsDomainEnvironmentKey] = domain }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a full pipe would block the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    @Test func itIsInTheAppAndCarriesTheAppsVersion() throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.binary.path))
        let version = try #require(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        for flag in ["--version", "-v"] {
            let result = try run([flag], support: try CT.shortDir())
            #expect(result.status == 0 && result.stdout == "\(version)\n" && result.stderr.isEmpty)
        }
    }

    @Test func helpAndUsageErrors() throws {
        let support = try CT.shortDir()
        let help = try run(["--help"], support: support)
        #expect(help.status == 0 && help.stdout.contains("usage:"))
        let usage = try run(["latest", "-n", "99"], support: support)
        #expect(usage.status == 2 && usage.stdout.isEmpty && usage.stderr.contains("usage: clipshot latest"))
        #expect(try run(["frobnicate"], support: support).status == 2)
    }

    @Test func commandsThatNeedTheAppSayHowToStartIt() throws {
        let support = try CT.shortDir()
        for command in ["pause", "resume", "copy", "clean"] {
            let result = try run([command], support: support)
            #expect(result.status == 3, "\(command)")
            #expect(result.stderr.contains("open -a ClipShot"))
        }
    }

    /// The binary's request crosses a real socket to a server in this process and its answer
    /// comes back as JSON on stdout.
    @Test func aRoundTripThroughTheSocket() throws {
        let support = try CT.shortDir()
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: support))
        try server.start()
        defer { server.stop() }
        let result = try run(["status", "--json"], support: support)
        #expect(result.status == 0, "\(result.stderr)")
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(result.stdout.utf8))
        #expect(status == StubHandler.status)
        #expect(stub.seen == [ControlRequest(command: .status)])
    }

    /// A socket left by a crash: nobody answers, so status reads for itself (a defaults
    /// domain nobody uses: never set up, so no folder is read) and exits 0.
    @Test func statusAgainstAStaleSocketReadsForItself() throws {
        let support = try CT.shortDir()
        try CT.staleSocket(at: CT.socket(in: support).path)
        let result = try run(["status", "--json"], support: support, domain: "sk.moravcik.ClipShot.tests.\(UUID().uuidString)")
        #expect(result.status == 0, "\(result.stderr)")
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(result.stdout.utf8))
        #expect(!status.running && status.pausedBy == .notRunning && status.folder == nil && status.attention == nil)
    }

    @Test func aSymlinkAtTheSocketPathIsNotUsed() throws {
        let support = try CT.shortDir()
        try FileManager.default.createSymbolicLink(
            atPath: CT.socket(in: support).path, withDestinationPath: "/private/var/run/syslog")
        let result = try run(["pause"], support: support)
        #expect(result.status == 1 && result.stderr.contains("is not ClipShot's socket"))
    }
}
