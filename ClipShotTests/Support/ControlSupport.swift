import Foundation
import Synchronization
@testable import ClipShot

/// Helpers for the control socket tests. Every socket lives in its own short folder in
/// the per-user temporary directory, under one `csk` parent, which macOS cleans like the
/// other fixtures: a socket path must fit in 104 bytes, so the names stay short. Nothing
/// here touches ClipShot's real folder or a running ClipShot.
enum CT {
    static func shortDir() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("csk", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var template = Array((parent.path + "/XXXXXX").utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        guard let made else { throw POSIXError(.EIO) }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    /// A socket that listens at `path` for as long as the returned descriptor is open.
    static func listening(at path: String) throws -> Int32 {
        let fd = ControlSocket.makeSocket()
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard ControlSocket.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
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

/// Holds whoever waits on it until `open()`: a handler the test lets go, instead of one
/// that takes a fixed time.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A handler that records what it was asked and answers with a fixed status.
final class StubHandler: Sendable {
    private let requests = Mutex<[ControlRequest]>([])
    /// Each answer waits for it, when there is one.
    private let gate: Gate?

    init(gate: Gate? = nil) {
        self.gate = gate
    }
    var seen: [ControlRequest] { requests.withLock { $0 } }

    static let status = ControlStatus(
        running: true, appVersion: "9.9.9", copying: true, pausedBy: nil, folder: "/tmp/shots",
        retention: ControlStatus.Retention(enabled: false, days: 30, refusal: nil), latest: nil)

    func handle(_ request: ControlRequest) async -> ControlResponse {
        requests.withLock { $0.append(request) }
        if let gate { await gate.wait() }
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
    func offlineSources(
        _ preferences: Preferences? = nil, appRunning: Bool = false, launchedRecently: Bool = false
    ) -> CLIOfflineSources {
        let folder = folder
        let home = home
        let stored = preferences ?? self.preferences
        return CLIOfflineSources(
            ledgerURL: ledgerURL, folder: { folder }, preferences: { stored },
            retentionRefusal: { $0.refusal(folder: folder, home: home, hasTrash: RT.hasTrash) },
            appRunning: { appRunning }, appLaunchedRecently: { launchedRecently })
    }

    /// `clipshot` talking to the socket in `dir`. `appRunning`: what the tool finds when the
    /// socket does not answer.
    func tool(
        _ dir: URL, workingDirectory: URL? = nil, offline: Preferences? = nil, appRunning: Bool = false,
        launchedRecently: Bool = false
    ) -> CommandLineTool {
        CommandLineTool(
            version: "0.9.0", socket: CT.socket(in: dir), workingDirectory: workingDirectory ?? home,
            offline: offlineSources(offline, appRunning: appRunning, launchedRecently: launchedRecently))
    }
}
