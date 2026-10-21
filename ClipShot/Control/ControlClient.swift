import Foundation

/// `clipshot`'s end of the control socket: one request, one response.
enum ControlClient {
    enum Failure: Error, Equatable {
        /// Nothing answers at the socket path: ClipShot is not running.
        case notRunning
        /// A symlink, a file or another user's socket is at the socket path; it is never used.
        case unsafeSocket
        /// The app took longer than the timeout to answer.
        case timedOut
        /// The answer was not a response this `clipshot` reads.
        case badResponse
        /// The app speaks another protocol version.
        case version(Int)
        case system(Int32)
    }

    /// How long `connect` may wait for the app to accept.
    static let connectTimeout: Duration = .seconds(2)

    static func send(
        _ request: ControlRequest, to socket: URL, timeout: Duration, owner: uid_t = geteuid()
    ) -> Result<ControlResponse, Failure> {
        let path = socket.path
        switch ControlSocket.inspect(path) {
        case .missing:
            return .failure(.notRunning)
        case .symlink, .other:
            return .failure(.unsafeSocket)
        case .socket(let socketOwner):
            guard socketOwner == owner else { return .failure(.unsafeSocket) }
        case .unreadable(let error):
            return error == EACCES ? .failure(.unsafeSocket) : .failure(.system(error))
        }
        let fd = ControlSocket.makeSocket()
        guard fd >= 0 else { return .failure(.system(errno)) }
        defer { close(fd) }
        let connected = ControlSocket.connect(fd, to: path, until: .now + connectTimeout)
        switch connected {
        case 0: break
        case ECONNREFUSED, ENOENT: return .failure(.notRunning)
        case ETIMEDOUT: return .failure(.timedOut)
        default: return .failure(.system(connected))
        }
        // The kernel's word on who listens: the app, as this user.
        guard ControlSocket.peerUID(fd) == owner else { return .failure(.unsafeSocket) }

        let deadline = ContinuousClock.now + timeout
        guard let body = try? ControlProtocol.encoder().encode(request) else { return .failure(.badResponse) }
        // A failed write still reads: the app may have answered why (a request too large).
        if ControlSocket.writeAll(fd, body, until: deadline) { shutdown(fd, SHUT_WR) }
        switch ControlSocket.readAll(fd, maxBytes: ControlProtocol.maxResponseBytes, until: deadline) {
        case .data(let data):
            return decode(data)
        case .timedOut:
            return .failure(.timedOut)
        case .tooLarge, .failed:
            return .failure(.badResponse)
        }
    }

    static func decode(_ data: Data) -> Result<ControlResponse, Failure> {
        let decoder = ControlProtocol.decoder()
        guard let envelope = try? decoder.decode(ControlEnvelope.self, from: data) else { return .failure(.badResponse) }
        guard envelope.v == ControlProtocol.version else { return .failure(.version(envelope.v)) }
        guard let response = try? decoder.decode(ControlResponse.self, from: data) else { return .failure(.badResponse) }
        return .success(response)
    }
}
