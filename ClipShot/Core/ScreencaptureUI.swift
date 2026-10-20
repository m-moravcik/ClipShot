import AppKit

enum ScreencaptureUI {
    /// True while the system screenshot UI is alive. Never terminated by ClipShot
    /// (spike F10); a settings change then applies from the next screenshot.
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.screencaptureui"
        ).isEmpty
    }
}
