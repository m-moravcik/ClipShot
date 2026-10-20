import Foundation
import ServiceManagement

/// Wrapper around SMAppService.mainApp - the modern macOS 13+ way to register
/// a menubar app to launch at login. No helper bundle needed.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// What to do when the stored user intent and the system's registration
    /// disagree. Pure so the decision can be tested without SMAppService.
    enum Reconciliation: Equatable {
        case nothingToDo
        case reRegister
        case unregister
        case adoptSystemState(enabled: Bool)
    }

    /// What the welcome tour's switch shows before the user has chosen: on (owner
    /// decision 2026-10-20). ClipShot copies only while it runs, so after a restart
    /// without it every screenshot would silently stop reaching the clipboard.
    static let tourDefault = true

    /// Whether watching reconciles at its start. Not during a first tour: nothing is
    /// stored yet, and adopting the system's "off" there would turn the tour's switch,
    /// which starts on, off before the user sees it. The tour's end decides instead.
    static func reconcilesAtStart(storedIntent: Bool?, onboardingShown: Bool) -> Bool {
        storedIntent != nil || onboardingShown
    }

    /// What ending the tour stores when the user did not touch the switch: the tour's
    /// default when the switch was on screen (step 3), else nil, meaning take the
    /// system's word as for any launch. A stored choice is kept.
    static func intentAtTourEnd(storedIntent: Bool?, switchShown: Bool) -> Bool? {
        storedIntent ?? (switchShown ? tourDefault : nil)
    }

    static func reconciliation(storedIntent: Bool?, systemEnabled: Bool) -> Reconciliation {
        // No record yet: this is the first launch after the intent key shipped.
        // Take the system's word for it rather than flipping the setting under
        // an existing user.
        guard let storedIntent else { return .adoptSystemState(enabled: systemEnabled) }

        if storedIntent == systemEnabled { return .nothingToDo }
        return storedIntent ? .reRegister : .unregister
    }

    /// Applies `reconciliation` and returns the intent that should be stored.
    ///
    /// Called once at launch. If a re-registration fails the intent is kept, not
    /// cleared: the user still wants launch-at-login, and silently forgetting
    /// that is the bug this whole mechanism exists to prevent.
    @discardableResult
    static func reconcile(storedIntent: Bool?) -> Bool {
        switch reconciliation(storedIntent: storedIntent, systemEnabled: isEnabled) {
        case .nothingToDo:
            return storedIntent ?? isEnabled
        case .adoptSystemState(let enabled):
            return enabled
        case .reRegister:
            setEnabled(true)
            return true
        case .unregister:
            setEnabled(false)
            return false
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
