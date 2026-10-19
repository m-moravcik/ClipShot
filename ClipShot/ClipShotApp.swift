import SwiftUI

@main
struct ClipShotApp: App {
    /// Nil under XCTest so the test host stays inert (no watcher, no pasteboard writes).
    @State private var model: AppModel?

    init() {
        _model = State(initialValue: Self.makeModel(environment: ProcessInfo.processInfo.environment))
    }

    static func makeModel(environment: [String: String]) -> AppModel? {
        if environment["XCTestConfigurationFilePath"] != nil { return nil }
        return MainActor.assumeIsolated { AppModel() }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(verbatim: "ClipShot")
                .padding(Design.Spacing.l)
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}
