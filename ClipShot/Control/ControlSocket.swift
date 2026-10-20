import Foundation

/// The POSIX side of the control socket, shared by the app (`ControlServer`) and
/// `clipshot` (`ControlClient`). Every descriptor is close-on-exec, never raises SIGPIPE and
/// is non-blocking: every read and write waits in `poll` against a deadline, so neither side
/// can be held by a peer that stops talking.
enum ControlSocket {
    /// What is at the socket path, read with `lstat` (a symlink is never followed).
    enum PathState: Equatable {
        case missing
        case socket(owner: uid_t)
        case symlink
        /// A file, folder or anything else that is not a socket.
        case other
        case unreadable(Int32)
    }

    static func inspect(_ path: String) -> PathState {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .missing : .unreadable(errno) }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFSOCK: return .socket(owner: st.st_uid)
        default: return .other
        }
    }

    /// The longest path a `sockaddr_un` holds, without its terminating NUL.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// Calls `body` with the address of `path`; nil when the path is too long for one.
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathLength, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + bytes.count + 1)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    /// A stream socket: close-on-exec, no SIGPIPE, non-blocking. -1 on failure.
    static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        guard prepare(fd) else {
            close(fd)
            return -1
        }
        return fd
    }

    /// Close-on-exec, no SIGPIPE, non-blocking: for a socket made here or one `accept`ed.
    static func prepare(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { return false }
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// The user at the other end of a connected socket, from the kernel (`getpeereid`).
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Milliseconds left until `deadline`, at least 0, for `poll`.
    private static func remaining(_ deadline: ContinuousClock.Instant) -> Int32 {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return 0 }
        let ms = left.components.seconds * 1_000 + left.components.attoseconds / 1_000_000_000_000_000
        return Int32(clamping: max(ms, 1))
    }

    /// Waits until `fd` is ready for `events`; false when the deadline passed first.
    static func wait(_ fd: Int32, for events: Int16, until deadline: ContinuousClock.Instant) -> Bool {
        while true {
            let timeout = remaining(deadline)
            guard timeout > 0 else { return false }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&entry, 1, timeout)
            if n > 0 { return true }
            if n == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    enum ReadResult: Equatable {
        case data(Data)
        /// More than the limit arrived; the rest is not read.
        case tooLarge
        case timedOut
        case failed
    }

    /// Everything up to end of file, at most `maxBytes`.
    static func readAll(_ fd: Int32, maxBytes: Int, until deadline: ContinuousClock.Instant) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
                if data.count > maxBytes { return .tooLarge }
            } else if n == 0 {
                return .data(data)
            } else if errno == EAGAIN || errno == EINTR {
                guard wait(fd, for: Int16(POLLIN), until: deadline) else { return .timedOut }
            } else {
                return .failed
            }
        }
    }

    /// All of `data`; false on an error or when the deadline passed first.
    static func writeAll(_ fd: Int32, _ data: Data, until deadline: ContinuousClock.Instant) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Connects `fd` to the socket at `path`. 0, or the errno that stopped it (`ETIMEDOUT`
    /// when the deadline passed, `ENAMETOOLONG` for a path no address holds).
    static func connect(_ fd: Int32, to path: String, until deadline: ContinuousClock.Instant) -> Int32 {
        guard let rc = withAddress(path, { Darwin.connect(fd, $0, $1) }) else { return ENAMETOOLONG }
        if rc == 0 { return 0 }
        let failure = errno
        // A full backlog: wait for the server to accept, as a blocking connect would.
        guard failure == EINPROGRESS || failure == EAGAIN || failure == EINTR else { return failure }
        if failure == EAGAIN { return retryConnect(fd, path, deadline) }
        guard wait(fd, for: Int16(POLLOUT), until: deadline) else { return ETIMEDOUT }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
        return error
    }

    /// A Unix socket's `connect` says EAGAIN when the listen backlog is full; it is tried
    /// again every 20 ms until the deadline.
    private static func retryConnect(_ fd: Int32, _ path: String, _ deadline: ContinuousClock.Instant) -> Int32 {
        while ContinuousClock.now < deadline {
            usleep(20_000)
            guard let rc = withAddress(path, { Darwin.connect(fd, $0, $1) }) else { return ENAMETOOLONG }
            if rc == 0 || errno == EISCONN { return 0 }
            if errno != EAGAIN { return errno }
        }
        return ETIMEDOUT
    }
}
