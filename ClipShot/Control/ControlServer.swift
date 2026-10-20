import Foundation
import Synchronization

/// The app's end of the control socket (Addendum C): `clipshot` asks, the app's model answers.
///
/// - The socket lives in a folder that must be a real folder (not a symlink) owned by this
///   user; it is made 0700. The socket file is 0600.
/// - What is already at the socket path is read with `lstat` and never followed: a symlink,
///   a file, a folder or another user's socket is left alone and the server does not start.
///   A socket of this user that nobody answers on is a leftover from a crash and is replaced;
///   one that answers belongs to another running ClipShot and is left to it.
/// - Replacing never deletes: the new socket is bound under a temporary name in the same
///   folder and renamed over the path, which replaces the leftover in one step.
/// - Every connection is checked with `getpeereid` before a byte is read: a peer of another
///   user is closed unanswered. One JSON request (at most `Limits.maxRequestBytes`, within
///   `Limits.readTimeout`), one JSON response (within `Limits.writeTimeout`), then the
///   connection closes. At most `Limits.maxConnections` are served at once; one more is told
///   the app is busy. A command that does not finish within its deadline is answered
///   "timed out" and its place is freed, whatever the work it started still does.
final class ControlServer: Sendable {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    struct Limits: Sendable {
        var readTimeout: Duration = .seconds(2)
        var writeTimeout: Duration = .seconds(5)
        var maxRequestBytes = ControlProtocol.maxRequestBytes
        var maxConnections = 8
        /// How long a command may take before it is answered "timed out": shorter than
        /// `clipshot`'s own wait, so the tool gets the answer.
        var handlerTimeout: Duration = .seconds(25)
        /// `clean`: a run moves up to 500 files to the Trash.
        var cleanTimeout: Duration = .seconds(170)

        func timeout(for command: ControlRequest.Command) -> Duration {
            command == .clean ? cleanTimeout : handlerTimeout
        }
    }

    enum StartError: Error, Equatable {
        /// The socket path does not fit a socket address.
        case pathTooLong
        /// The socket's folder is a symlink, not a folder, or another user's.
        case unsafeFolder
        /// A symlink, a file, a folder or another user's socket is at the socket path.
        case unsafeSocketPath
        /// Another ClipShot answers on the socket.
        case inUse
        case alreadyStarted
        case system(Int32)
    }

    let socketURL: URL
    /// The only user whose connections are served: the one the app runs as.
    private let allowedPeer: uid_t
    private let limits: Limits
    private let log: Log
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "sk.moravcik.ClipShot.control.accept")
    private let ioQueue = DispatchQueue(label: "sk.moravcik.ClipShot.control.io", attributes: .concurrent)

    private struct State {
        var fd: Int32 = -1
        var source: (any DispatchSourceRead)?
        var active = 0
        var answered = 0
        var refusedPeers = 0
        var dropped = 0
    }

    private let state = Mutex(State())

    init(
        socketURL: URL = ControlProtocol.defaultSocketURL, allowedPeer: uid_t = geteuid(),
        limits: Limits = Limits(), log: Log = .shared, handler: @escaping Handler
    ) {
        self.socketURL = socketURL
        self.allowedPeer = allowedPeer
        self.limits = limits
        self.log = log
        self.handler = handler
    }

    deinit {
        state.withLock { $0.source?.cancel() }
    }

    // MARK: Test hooks

    /// Connections answered (a response written or tried), refused for their user, and
    /// closed without an answer (too many at once, a timeout, a read error).
    var answered: Int { state.withLock { $0.answered } }
    /// Connections being served now.
    var active: Int { state.withLock { $0.active } }
    var refusedPeers: Int { state.withLock { $0.refusedPeers } }
    var dropped: Int { state.withLock { $0.dropped } }

    // MARK: Lifecycle

    func start() throws(StartError) {
        guard state.withLock({ $0.fd < 0 }) else { throw .alreadyStarted }
        let path = socketURL.path
        let folder = socketURL.deletingLastPathComponent().path
        let temporary = (folder as NSString).appendingPathComponent(
            ".clipshot-\(getpid())-\(UInt32.random(in: .min ... .max)).sock")
        guard path.utf8.count <= ControlSocket.maxPathLength, temporary.utf8.count <= ControlSocket.maxPathLength
        else { throw .pathTooLong }
        try Self.prepareFolder(folder)
        switch ControlSocket.inspect(path) {
        case .missing:
            break
        case .symlink, .other:
            throw .unsafeSocketPath
        case .socket(let owner):
            guard owner == geteuid() else { throw .unsafeSocketPath }
            if Self.answers(path) { throw .inUse }
        case .unreadable(let error):
            throw .system(error)
        }

        let fd = ControlSocket.makeSocket()
        guard fd >= 0 else { throw .system(errno) }
        let bound = ControlSocket.withAddress(temporary) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw .system(error)
        }
        // The folder is 0700 already; the socket itself is 0600 before anyone can find it.
        guard chmod(temporary, 0o600) == 0, listen(fd, 16) == 0, rename(temporary, path) == 0 else {
            let error = errno
            close(fd)
            let log = log
            Task { await log.error("control socket not started (errno \(error)); a temporary socket file may be left") }
            throw .system(error)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        state.withLock {
            $0.fd = fd
            $0.source = source
        }
        source.resume()
    }

    /// Stops listening. The socket file stays; the next start replaces it.
    func stop() {
        state.withLock {
            $0.source?.cancel()
            $0.source = nil
            $0.fd = -1
        }
    }

    // MARK: Folder and leftovers

    /// Makes the folder (0700) if needed, then requires a real folder owned by this user
    /// and closes it to everyone else.
    static func prepareFolder(_ folder: String) throws(StartError) {
        if mkdir(folder, 0o700) != 0, errno != EEXIST {
            // A missing parent (a fresh account without Application Support): make it.
            do {
                try FileManager.default.createDirectory(
                    atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw .system(errno)
            }
        }
        var st = stat()
        guard lstat(folder, &st) == 0 else { throw .system(errno) }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else { throw .unsafeFolder }
        if st.st_mode & 0o077 != 0, chmod(folder, 0o700) != 0 { throw .system(errno) }
    }

    /// Whether a server answers on the socket at `path` now.
    static func answers(_ path: String) -> Bool {
        let fd = ControlSocket.makeSocket()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return ControlSocket.connect(fd, to: path, until: .now + .milliseconds(500)) == 0
    }

    // MARK: Connections

    private func acceptAll() {
        let fd = state.withLock { $0.fd }
        guard fd >= 0 else { return }
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard ControlSocket.prepare(client) else {
                close(client)
                continue
            }
            guard ControlSocket.peerUID(client) == allowedPeer else {
                close(client)
                state.withLock { $0.refusedPeers += 1 }
                let log = log
                Task { await log.error("control: refused a connection from another user") }
                continue
            }
            let admitted = state.withLock { state -> Bool in
                guard state.active < limits.maxConnections else { return false }
                state.active += 1
                return true
            }
            guard admitted else {
                // Said, not just closed: a closed connection reads as a broken answer. The
                // reply is a few bytes into an empty socket buffer, bounded anyway.
                if let data = try? ControlProtocol.encoder().encode(ControlResponse.failure(
                    .busy, "ClipShot is busy with other clipshot commands; try again.")) {
                    _ = ControlSocket.writeAll(client, data, until: .now + .milliseconds(100))
                }
                close(client)
                state.withLock { $0.dropped += 1 }
                continue
            }
            ioQueue.async { self.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        switch ControlSocket.readAll(client, maxBytes: limits.maxRequestBytes, until: .now + limits.readTimeout) {
        case .data(let data):
            switch Self.decode(data) {
            case .failure(let failure):
                reply(ControlResponse(error: failure), to: client)
            case .success(let request):
                handle(request, client: client)
            }
        case .tooLarge:
            reply(.failure(.tooLarge, "The request is larger than \(limits.maxRequestBytes) bytes."), to: client)
        case .timedOut, .failed:
            close(client)
            state.withLock {
                $0.active -= 1
                $0.dropped += 1
            }
        }
    }

    /// The request, or the answer that refuses it: another protocol version, or not a
    /// request at all.
    static func decode(_ data: Data) -> Result<ControlRequest, ControlFailure> {
        let decoder = ControlProtocol.decoder()
        guard let envelope = try? decoder.decode(ControlEnvelope.self, from: data) else {
            return .failure(ControlFailure(code: .badRequest, message: "The request is not one ClipShot understands."))
        }
        guard envelope.v == ControlProtocol.version else {
            return .failure(ControlFailure(
                code: .version,
                message: "This clipshot speaks protocol \(envelope.v), ClipShot speaks \(ControlProtocol.version). "
                    + "Use the clipshot that comes with ClipShot.app."))
        }
        guard let request = try? decoder.decode(ControlRequest.self, from: data) else {
            return .failure(ControlFailure(code: .badRequest, message: "The request is not one ClipShot understands."))
        }
        return .success(request)
    }

    /// Runs the handler against its deadline. Whichever ends first answers, once; a handler
    /// that ends later is not heard, and the connection's place is free again either way.
    private func handle(_ request: ControlRequest, client: Int32) {
        let once = AnswerOnce()
        let claim: @Sendable () -> Bool = { once.claim() }
        let handler = handler
        let timeout = limits.timeout(for: request.command)
        Task {
            let response = await handler(request)
            if claim() { self.ioQueue.async { self.reply(response, to: client) } }
        }
        ioQueue.asyncAfter(deadline: .now() + Self.seconds(timeout)) {
            guard claim() else { return }
            let log = self.log
            Task { await log.error("control: \(request.command.rawValue) timed out") }
            self.reply(.failure(.timedOut, "ClipShot did not finish in time. It may still finish; check with clipshot status."), to: client)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func reply(_ response: ControlResponse, to client: Int32) {
        if let data = try? ControlProtocol.encoder().encode(response) {
            _ = ControlSocket.writeAll(client, data, until: .now + limits.writeTimeout)
        }
        close(client)
        state.withLock {
            $0.active -= 1
            $0.answered += 1
        }
    }
}

/// True for the first `claim()` only: the handler's answer or the deadline's, never both.
private final class AnswerOnce: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
        claimed.withLock { done in
            defer { done = true }
            return !done
        }
    }
}
