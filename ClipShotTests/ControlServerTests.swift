import Foundation
import Testing
@testable import ClipShot

/// The control socket `clipshot` talks to (Addendum C): a request goes in and an answer comes
/// out; another user's connection, an oversize or a silent request, and another protocol
/// version are refused; whatever already sits at the socket path is never followed and is
/// replaced only when it is this user's leftover socket.
struct ControlServerTests {
    // MARK: Round trip

    @Test func aRequestGetsTheHandlersAnswer() throws {
        let dir = try CT.shortDir()
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        let request = ControlRequest(command: .latest, count: 3)
        let response = try ControlClient.send(request, to: CT.socket(in: dir), timeout: .seconds(5)).get()
        #expect(response.status == StubHandler.status)
        #expect(stub.seen == [request])
        // Several in a row, one connection each.
        for _ in 0..<3 {
            #expect((try? ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(5)).get()) != nil)
        }
        #expect(stub.seen.count == 4)
    }

    @Test func theFolderIs0700AndTheSocket0600() throws {
        let dir = try CT.shortDir()
        chmod(dir.path, 0o755)
        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        #expect(CT.mode(dir.path) == 0o700)
        #expect(CT.mode(CT.socket(in: dir).path) == 0o600)
        #expect(ControlSocket.inspect(CT.socket(in: dir).path) == .socket(owner: geteuid()))
    }

    @Test func theFolderIsMadeWhenMissing() throws {
        let dir = try CT.shortDir().appendingPathComponent("new", isDirectory: true)
        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        #expect(CT.mode(dir.path) == 0o700)
    }

    // MARK: Peers

    /// `getpeereid` says who connected; anyone but the expected user is closed unanswered and
    /// never reaches the handler. (The test cannot connect as another user, so the server is
    /// told to expect a different one.)
    @Test func aPeerOfAnotherUserIsRefusedUnanswered() async throws {
        let dir = try CT.shortDir()
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: dir), allowedPeer: geteuid() + 1)
        try server.start()
        defer { server.stop() }
        let answer = CT.exchange(CT.socket(in: dir).path, CT.request(.pause))
        #expect(answer == Data(), "closed without a byte")
        #expect(ControlClient.send(ControlRequest(command: .pause), to: CT.socket(in: dir), timeout: .seconds(5)) == .failure(.badResponse))
        #expect(await eventually { server.refusedPeers == 2 })
        #expect(stub.seen.isEmpty)
    }

    // MARK: Requests refused

    @Test func anOversizeRequestIsRefusedUnhandled() throws {
        let dir = try CT.shortDir()
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        var big = ControlRequest(command: .copy)
        big.path = "/" + String(repeating: "a", count: ControlProtocol.maxRequestBytes)
        let body = try ControlProtocol.encoder().encode(big)
        let answer = try #require(CT.exchange(CT.socket(in: dir).path, body))
        let response = try ControlClient.decode(answer).get()
        #expect(response.error?.code == .tooLarge)
        #expect(stub.seen.isEmpty)
        // Through the client too: the answer is read although the write was cut short.
        let viaClient = try ControlClient.send(big, to: CT.socket(in: dir), timeout: .seconds(5)).get()
        #expect(viaClient.error?.code == .tooLarge)
    }

    @Test func aSilentPeerIsClosedAfterTheReadTimeout() async throws {
        let dir = try CT.shortDir()
        var limits = ControlServer.Limits()
        limits.readTimeout = .milliseconds(200)
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: dir), limits: limits)
        try server.start()
        defer { server.stop() }
        let started = ContinuousClock.now
        let answer = CT.exchange(CT.socket(in: dir).path, Data(), endWrite: false, timeout: .seconds(5))
        #expect(answer == Data(), "closed, nothing said")
        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(await eventually { server.dropped == 1 })
        #expect(stub.seen.isEmpty)
    }

    @Test func anotherVersionOrNotJSONIsRefusedClearly() throws {
        let dir = try CT.shortDir()
        let stub = StubHandler()
        let server = try stub.server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        let path = CT.socket(in: dir).path
        let other = try ControlClient.decode(try #require(CT.exchange(path, Data(#"{"v":99,"command":"launch"}"#.utf8)))).get()
        #expect(other.error?.code == .version)
        #expect(other.error?.message.contains("protocol 99") == true)
        for junk in ["not json", #"{"v":1,"command":"format-disk"}"#, #"{"v":1}"#] {
            let response = try ControlClient.decode(try #require(CT.exchange(path, Data(junk.utf8)))).get()
            #expect(response.error?.code == .badRequest)
        }
        #expect(stub.seen.isEmpty)
        // The client side of a version change.
        #expect(ControlClient.decode(Data(#"{"v":2,"status":null}"#.utf8)) == .failure(.version(2)))
        #expect(ControlClient.decode(Data("<html>".utf8)) == .failure(.badResponse))
    }

    // MARK: What is at the socket path

    @Test func aSymlinkAtTheSocketPathIsNeitherFollowedNorReplaced() throws {
        let dir = try CT.shortDir()
        let target = dir.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: CT.socket(in: dir).path, withDestinationPath: target.path)
        let server = try StubHandler().server(at: CT.socket(in: dir))
        #expect(throws: ControlServer.StartError.unsafeSocketPath) { try server.start() }
        #expect(ControlSocket.inspect(CT.socket(in: dir).path) == .symlink)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        // And the client never connects through one.
        #expect(ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1)) == .failure(.unsafeSocket))
    }

    @Test func aSymlinkToALiveSocketIsNotUsedEither() throws {
        let real = try CT.shortDir()
        let server = try StubHandler().server(at: CT.socket(in: real))
        try server.start()
        defer { server.stop() }
        let dir = try CT.shortDir()
        try FileManager.default.createSymbolicLink(atPath: CT.socket(in: dir).path, withDestinationPath: CT.socket(in: real).path)
        #expect(ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1)) == .failure(.unsafeSocket))
        #expect(throws: ControlServer.StartError.unsafeSocketPath) { try StubHandler().server(at: CT.socket(in: dir)).start() }
    }

    @Test func aFileAtTheSocketPathIsLeftAlone() throws {
        let dir = try CT.shortDir()
        try Data("mine".utf8).write(to: CT.socket(in: dir))
        #expect(throws: ControlServer.StartError.unsafeSocketPath) { try StubHandler().server(at: CT.socket(in: dir)).start() }
        #expect(try Data(contentsOf: CT.socket(in: dir)) == Data("mine".utf8))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        let folderPath = dir.appendingPathComponent("sub").appendingPathComponent(ControlProtocol.socketName)
        try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: false)
        #expect(throws: ControlServer.StartError.unsafeSocketPath) { try StubHandler().server(at: folderPath).start() }
    }

    /// A crash leaves the socket file behind: nobody answers on it, so it is replaced.
    @Test func aStaleSocketIsReplaced() throws {
        let dir = try CT.shortDir()
        try CT.staleSocket(at: CT.socket(in: dir).path)
        #expect(ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1)) == .failure(.notRunning))
        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        #expect((try? ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(5)).get()) != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == [ControlProtocol.socketName], "the temporary name is gone")
        #expect(CT.mode(CT.socket(in: dir).path) == 0o600)
    }

    /// A socket another ClipShot answers on belongs to it: a second start leaves it be.
    @Test func aLiveSocketIsLeftToItsServer() throws {
        let dir = try CT.shortDir()
        let first = StubHandler()
        let running = try first.server(at: CT.socket(in: dir))
        try running.start()
        defer { running.stop() }
        #expect(throws: ControlServer.StartError.inUse) { try StubHandler().server(at: CT.socket(in: dir)).start() }
        _ = try ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(5)).get()
        #expect(first.seen.count == 1, "the first server still answers")
    }

    @Test func aSymlinkedOrForeignFolderIsRefused() throws {
        let real = try CT.shortDir()
        let parent = try CT.shortDir()
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        #expect(throws: ControlServer.StartError.unsafeFolder) { try StubHandler().server(at: CT.socket(in: link)).start() }
        // /var/root is root's: not this user's folder.
        #expect(throws: ControlServer.StartError.self) { try ControlServer.prepareFolder("/private/var/root") }
    }

    @Test func aPathTooLongForASocketAddressIsRefused() throws {
        let dir = try CT.shortDir().appendingPathComponent(String(repeating: "d", count: 120), isDirectory: true)
        #expect(throws: ControlServer.StartError.pathTooLong) { try StubHandler().server(at: CT.socket(in: dir)).start() }
        #expect(!FileManager.default.fileExists(atPath: dir.path), "nothing made")
    }

    // MARK: Load and deadlines

    /// One more connection than the server serves at once is told it is busy, not closed
    /// silently; the ones in flight finish.
    @Test func pastTheConnectionCapTheAnswerIsBusy() async throws {
        let dir = try CT.shortDir()
        var limits = ControlServer.Limits()
        limits.maxConnections = 2
        let gate = Gate()
        let stub = StubHandler(gate: gate)
        let server = try stub.server(at: CT.socket(in: dir), limits: limits)
        try server.start()
        defer { server.stop() }
        let socket = CT.socket(in: dir)
        let held = (0..<2).map { _ in
            Task.detached { ControlClient.send(ControlRequest(command: .status), to: socket, timeout: .seconds(10)) }
        }
        #expect(await eventually { server.active == 2 && stub.seen.count == 2 })
        let busy = try await Task.detached {
            try ControlClient.send(ControlRequest(command: .status), to: socket, timeout: .seconds(5)).get()
        }.value
        #expect(busy.error?.code == .busy)
        gate.open()
        for task in held { #expect((try? await task.value.get())?.status == StubHandler.status) }
        #expect(stub.seen.count == 2, "the busy request never reached the handler")
        #expect(await eventually { server.active == 0 })
    }

    /// A command that outlives its deadline is answered "timed out" and frees its place.
    @Test func aStuckCommandIsAnsweredAtItsDeadline() async throws {
        let dir = try CT.shortDir()
        var limits = ControlServer.Limits()
        limits.handlerTimeout = .milliseconds(200)
        limits.cleanTimeout = .seconds(60)
        #expect(limits.timeout(for: .clean) == .seconds(60) && limits.timeout(for: .status) == .milliseconds(200))
        let gate = Gate()
        defer { gate.open() }
        let stub = StubHandler(gate: gate)
        let server = try stub.server(at: CT.socket(in: dir), limits: limits)
        try server.start()
        defer { server.stop() }
        let socket = CT.socket(in: dir)
        let response = try await Task.detached {
            try ControlClient.send(ControlRequest(command: .status), to: socket, timeout: .seconds(10)).get()
        }.value
        #expect(response.error?.code == .timedOut, "answered while the handler is still held")
        #expect(await eventually { server.active == 0 }, "the place is free while the work goes on")
    }

    @Test func theClientGivesUpAtItsTimeout() async throws {
        let dir = try CT.shortDir()
        let gate = Gate()
        defer { gate.open() }
        let server = try StubHandler(gate: gate).server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        let socket = CT.socket(in: dir)
        let result = await Task.detached {
            ControlClient.send(ControlRequest(command: .status), to: socket, timeout: .milliseconds(300))
        }.value
        #expect(result == .failure(.timedOut), "the handler is held: only the client's timeout can end it")
    }

    // MARK: Leftover temporary sockets

    @Test func leftoverNamesAreRecognisedExactly() {
        #expect(ControlServer.leftoverPID(".clipshot-123-4567.sock") == 123)
        for name in ["clipshot.sock", ".clipshot-123.sock", ".clipshot-12a-4.sock", ".clipshot-1-2-3.sock",
                     ".clipshot--4.sock", ".clipshot-1-.sock", ".clipshot-1-2.sock.bak", "x.clipshot-1-2.sock"] {
            #expect(ControlServer.leftoverPID(name) == nil, "\(name)")
        }
    }

    /// Stale temporary sockets of another process are swept by rename; a file with such a
    /// name, a live one and one of this process stay.
    @Test func staleTemporarySocketsAreSweptByRename() throws {
        let dir = try CT.shortDir()
        let stale = [".clipshot-999999-1.sock", ".clipshot-999999-2.sock"].map { dir.appendingPathComponent($0).path }
        for path in stale { try CT.staleSocket(at: path) }
        let file = dir.appendingPathComponent(".clipshot-999999-3.sock")
        try Data("keep".utf8).write(to: file)
        let live = dir.appendingPathComponent(".clipshot-999998-4.sock").path
        let liveFD = try CT.listening(at: live)
        defer { close(liveFD) }
        let own = dir.appendingPathComponent(".clipshot-\(getpid())-5.sock").path
        try CT.staleSocket(at: own)

        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        for path in stale { #expect(ControlSocket.inspect(path) == .missing, "\(path)") }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        #expect(ControlSocket.inspect(live) == .socket(owner: geteuid()) && ControlServer.answers(live))
        #expect(ControlSocket.inspect(own) == .socket(owner: geteuid()), "this process's own name is left alone")
        #expect((try? ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(5)).get()) != nil)
    }

    // MARK: The client

    @Test func noSocketOrNobodyListeningIsNotRunning() throws {
        let dir = try CT.shortDir()
        #expect(ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1)) == .failure(.notRunning))
        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        server.stop()
        #expect(ControlClient.send(ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1)) == .failure(.notRunning))
    }

    @Test func theClientRefusesASocketOfAnotherOwner() throws {
        let dir = try CT.shortDir()
        let server = try StubHandler().server(at: CT.socket(in: dir))
        try server.start()
        defer { server.stop() }
        #expect(ControlClient.send(
            ControlRequest(command: .status), to: CT.socket(in: dir), timeout: .seconds(1), owner: geteuid() + 1)
            == .failure(.unsafeSocket))
    }
}
