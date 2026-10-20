import Foundation
import Synchronization
@testable import ClipShot

/// Helpers for the control socket tests. Every socket lives in its own folder under /tmp:
/// a socket path must fit in 104 bytes, which the per-user temporary directory leaves too
/// little room for. Nothing here touches ClipShot's real folder or a running ClipShot.
enum CT {
    static func shortDir() throws -> URL {
        var template = Array("/tmp/csk.XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        guard let made else { throw POSIXError(.EIO) }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    static func socket(in dir: URL) -> URL { dir.appendingPathComponent(ControlProtocol.socketName) }

    /// Connects to the socket at `path`, writes `bytes` (and ends the write side unless
    /// `endWrite` is false) and reads what comes back until the server closes. nil when it
    /// could not connect.
    static func exchange(_ path: String, _ bytes: Data, endWrite: Bool = true, timeout: Duration = .seconds(5)) -> Data? {
        let fd = ControlSocket.makeSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let deadline = ContinuousClock.now + timeout
        guard ControlSocket.connect(fd, to: path, until: deadline) == 0 else { return nil }
        _ = ControlSocket.writeAll(fd, bytes, until: deadline)
        if endWrite { shutdown(fd, SHUT_WR) }
        guard case .data(let data) = ControlSocket.readAll(fd, maxBytes: 1 << 20, until: deadline) else { return nil }
        return data
    }

    /// A socket file nobody listens on: what a crash leaves behind.
    static func staleSocket(at path: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let rc = ControlSocket.withAddress(path) { bind(fd, $0, $1) }
        guard rc == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    static func mode(_ path: String) -> mode_t {
        var st = stat()
        lstat(path, &st)
        return st.st_mode & 0o777
    }

    static func request(_ command: ControlRequest.Command) -> Data {
        try! ControlProtocol.encoder().encode(ControlRequest(command: command))
    }
}

/// A handler that records what it was asked and answers with a fixed status.
final class StubHandler: Sendable {
    private let requests = Mutex<[ControlRequest]>([])
    var seen: [ControlRequest] { requests.withLock { $0 } }

    static let status = ControlStatus(
        running: true, appVersion: "9.9.9", copying: true, pausedBy: nil, folder: "/tmp/shots",
        retention: ControlStatus.Retention(enabled: false, days: 30, refusal: nil), latest: nil)

    func handle(_ request: ControlRequest) async -> ControlResponse {
        requests.withLock { $0.append(request) }
        return ControlResponse(status: Self.status)
    }

    func server(at socket: URL, allowedPeer: uid_t = geteuid(), limits: ControlServer.Limits = .init()) throws -> ControlServer {
        ControlServer(socketURL: socket, allowedPeer: allowedPeer, limits: limits, log: try RT.testLog()) { request in
            await self.handle(request)
        }
    }
}

extension ModelHarness {
    /// The app's control socket, in a short folder of its own, answered by this harness's model.
    func controlServer() throws -> (ControlServer, URL) {
        let dir = try CT.shortDir()
        let model = model
        let server = ControlServer(socketURL: CT.socket(in: dir), log: try RT.testLog()) { [weak model] request in
            guard let model else { return .failure(.notSetUp, "gone") }
            return await model.handleControl(request, appVersion: "0.9.0")
        }
        try server.start()
        return (server, dir)
    }

    /// What `clipshot` reads itself while the app is not running: this harness's ledger and
    /// folder, and `preferences`.
    func offlineSources(_ preferences: Preferences? = nil) -> CLIOfflineSources {
        let folder = folder
        let stored = preferences ?? self.preferences
        return CLIOfflineSources(ledgerURL: ledgerURL, folder: { folder }, preferences: { stored })
    }

    /// `clipshot` talking to the socket in `dir`.
    func tool(_ dir: URL, workingDirectory: URL? = nil, offline: Preferences? = nil) -> CommandLineTool {
        CommandLineTool(
            version: "0.9.0", socket: CT.socket(in: dir), workingDirectory: workingDirectory ?? home,
            offline: offlineSources(offline))
    }
}
