import Foundation

/// The app's control socket for `clipshot` (Addendum C). Started once at launch with the
/// app's model; never under XCTest, the screenshot harness or the probes, which have no
/// real model. A socket another running ClipShot answers on is left to it.
@MainActor
enum ControlHost {
    private static var server: ControlServer?
    private static var starting = false

    /// How long the second try waits when another instance still answers on the socket: a
    /// relaunch can start while the quitting instance is still exiting.
    nonisolated static let retryDelay: Duration = .seconds(2)

    /// Starts the server off the main thread (the folder checks, the probe of a socket left
    /// behind, bind and rename), so launch never waits on them.
    static func start(model: AppModel, socketURL: URL = ControlProtocol.defaultSocketURL) {
        guard server == nil, !starting else { return }
        starting = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let server = ControlServer(socketURL: socketURL) { [weak model] request in
            await Self.handle(request, model: model, appVersion: version)
        }
        Task.detached(priority: .utility) {
            let started = await Self.startWithRetry(server)
            await MainActor.run {
                starting = false
                if started { Self.server = server }
            }
        }
    }

    /// One try, and one more after `retryDelay` when another instance still answers.
    private nonisolated static func startWithRetry(_ server: ControlServer) async -> Bool {
        let log = Log.shared
        for attempt in 1...2 {
            do throws(ControlServer.StartError) {
                try server.start()
                await log.info("control socket listening")
                return true
            } catch .inUse where attempt == 1 {
                try? await Task.sleep(for: retryDelay)
            } catch {
                await log.error("control socket not started: \(error)")
                return false
            }
        }
        return false
    }

    private static func handle(_ request: ControlRequest, model: AppModel?, appVersion: String) async -> ControlResponse {
        guard let model else { return .failure(.notSetUp, ShortcutErrorText.notSetUp) }
        return await model.handleControl(request, appVersion: appVersion)
    }
}
