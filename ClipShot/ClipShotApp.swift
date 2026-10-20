import SwiftUI

@main
struct ClipShotApp: App {
    /// Nil under XCTest so the test host stays inert (no watcher, no pasteboard writes).
    @State private var model: AppModel?
    @State private var router = SettingsRouter()
    /// Nil under XCTest, like the model: no Sparkle, no network.
    private let updater: (any UpdaterProviding)?
    /// The updater's, or a status that never turns on when there is no updater.
    private let updateStatus: UpdateStatus

    init() {
        #if DEBUG
        // Before anything else: the harness renders demo data and exits, so the app never
        // starts watching or touches the pasteboard (scripts/screenshots.sh).
        if let output = ScreenshotHarness.requestedOutput {
            ScreenshotHarness.run(into: output)
        }
        // The same for motion: the real views play a scripted sequence live (scripts/motion-demo.sh).
        if let scheme = MotionDemo.requested {
            MotionDemo.run(scheme)
        }
        // The real menu bar on demo data: checks that Peg's moments reach the status item
        // while the popover is open (scripts/status-item-probe.sh). No updater, no real model.
        if let output = StatusItemProbe.requestedOutput {
            let model = MainActor.assumeIsolated { StatusItemProbe.makeModel() }
            _model = State(initialValue: model)
            updater = nil
            updateStatus = MainActor.assumeIsolated { UpdateStatus() }
            MainActor.assumeIsolated { StatusItemProbe.start(into: output) }
            return
        }
        #endif
        let model = Self.makeModel(environment: ProcessInfo.processInfo.environment)
        // Resumes watching only when onboarding was already shown; otherwise step 2 starts it.
        model?.launch()
        if let model {
            MainActor.assumeIsolated {
                // Shortcuts actions and the Focus filter act on this model (Addendum C).
                IntentHost.model = model
                Task { await model.reconcileFocusAtLaunch { try await CopyingFocusFilter.current.pauseCopying } }
                // `clipshot` reaches the same model over the control socket (Addendum C).
                ControlHost.start(model: model)
            }
        }
        _model = State(initialValue: model)
        let updater = Self.makeUpdater(environment: ProcessInfo.processInfo.environment)
        self.updater = updater
        updateStatus = MainActor.assumeIsolated { updater?.updateStatus ?? UpdateStatus() }
    }

    static func makeUpdater(environment: [String: String]) -> (any UpdaterProviding)? {
        if environment["XCTestConfigurationFilePath"] != nil { return nil }
        return MainActor.assumeIsolated { makeUpdaterController() }
    }

    /// Builds the model without starting it: creating it has no side effects.
    static func makeModel(environment: [String: String]) -> AppModel? {
        if environment["XCTestConfigurationFilePath"] != nil { return nil }
        return MainActor.assumeIsolated { AppModel(dependencies: .live()) }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model {
                MenuContent()
                    .environment(model)
                    .environment(router)
                    .environment(updateStatus)
                    .environment(\.updater, updater)
            }
        } label: {
            if let model {
                StatusIcon(state: model.iconState, pose: model.iconPose)
            } else {
                StatusIcon(state: .idle, pose: Peg.pose(.idle))
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let model {
                SettingsView()
                    .environment(model)
                    .environment(router)
                    .environment(updateStatus)
                    .environment(\.updater, updater)
            }
        }
    }
}
