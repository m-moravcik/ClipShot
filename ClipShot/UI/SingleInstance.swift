import AppKit

/// Only one ClipShot runs: a second one (another copy opened from a disk image, or the binary
/// run directly) would copy every screenshot twice and add a second menu bar icon. Launch
/// Services keeps a single instance only per app bundle, not per bundle identifier.
enum SingleInstance {
    /// How long another instance may take to exit: a relaunch can start while the quitting
    /// instance is still exiting.
    static let grace: Duration = .seconds(2)
    private static let step: Duration = .milliseconds(100)

    /// Exits before anything starts when another instance runs, never under XCTest. Blocks
    /// launch only while another instance exists: up to `grace` and a log write.
    static func exitIfAnotherRuns(environment: [String: String]) {
        guard environment["XCTestConfigurationFilePath"] == nil, let other = other() else { return }
        let logged = DispatchSemaphore(value: 0)
        Task.detached {
            await Log.shared.info("another ClipShot is running (pid \(other)), quitting")
            logged.signal()
        }
        _ = logged.wait(timeout: .now() + 1)
        exit(0)
    }

    /// Another instance of this app still running after up to `grace`, or nil.
    static func other() -> pid_t? {
        other(
            among: runningPIDs(),
            isAlive: { kill($0, 0) == 0 || errno == EPERM },
            sleep: { duration in
                let (seconds, attoseconds) = duration.components
                Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
            })
    }

    static func other(among pids: [pid_t], isAlive: (pid_t) -> Bool, sleep: (Duration) -> Void) -> pid_t? {
        var waited: Duration = .zero
        while let alive = pids.first(where: isAlive) {
            if waited >= grace { return alive }
            sleep(step)
            waited += step
        }
        return nil
    }

    /// Other processes with this app's bundle identifier; never this one.
    static func runningPIDs() -> [pid_t] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { !$0.isTerminated && $0.processIdentifier != own }
            .map(\.processIdentifier)
    }
}
