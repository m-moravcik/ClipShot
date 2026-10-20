import Foundation

/// The app's control socket for `clipshot` (Addendum C). Started once at launch with the
/// app's model; never under XCTest, the screenshot harness or the probes, which have no
/// real model. A socket another running ClipShot answers on is left to it.
@MainActor
enum ControlHost {
    private static var server: ControlServer?

    static func start(model: AppModel, socketURL: URL = ControlProtocol.defaultSocketURL) {
        guard server == nil else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let server = ControlServer(socketURL: socketURL) { [weak model] request in
            await Self.handle(request, model: model, appVersion: version)
        }
        let log = Log.shared
        do throws(ControlServer.StartError) {
            try server.start()
            self.server = server
            Task { await log.info("control socket listening") }
        } catch {
            Task { await log.error("control socket not started: \(error)") }
        }
    }

    private static func handle(_ request: ControlRequest, model: AppModel?, appVersion: String) async -> ControlResponse {
        guard let model else { return .failure(.notSetUp, ShortcutErrorText.notSetUp) }
        return await model.handleControl(request, appVersion: appVersion)
    }
}
