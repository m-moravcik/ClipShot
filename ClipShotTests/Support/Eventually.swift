import Foundation

/// Polls `condition` until it returns true or `timeout` elapses.
func eventually(
    timeout: Duration = .seconds(5),
    poll: Duration = .milliseconds(50),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return await condition()
}
