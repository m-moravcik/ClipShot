import SwiftUI

@main
struct ClipShotApp: App {
    /// Nil under XCTest so the test host stays inert (no watcher, no pasteboard writes).
    @State private var model: AppModel?

    init() {
        let model = Self.makeModel(environment: ProcessInfo.processInfo.environment)
        // Resumes watching only when onboarding was already shown; otherwise step 2 starts it.
        model?.launch()
        _model = State(initialValue: model)
    }

    /// Builds the model without starting it: creating it has no side effects.
    static func makeModel(environment: [String: String]) -> AppModel? {
        if environment["XCTestConfigurationFilePath"] != nil { return nil }
        return MainActor.assumeIsolated { AppModel(dependencies: .live()) }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(verbatim: "ClipShot")
                .padding(Design.Spacing.l)
        } label: {
            if let model {
                StatusIcon(state: model.iconState, phase: model.flashPhase, reduceMotion: model.flashReduceMotion)
            } else {
                StatusIcon(state: .idle, phase: 0)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
