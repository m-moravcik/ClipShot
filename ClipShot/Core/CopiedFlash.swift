import Foundation

/// Phase counter for the menu bar copy animation (`Peg.pose(at:)`).
///
/// A MenuBarExtra label is a static image, so the icon is redrawn by a timer that calls
/// `tick()` every `interval` seconds, and only while the animation plays. Phase 0 is off;
/// phases 1...`steps - 1` are the frames, phase `p` at `time(phase:)` seconds; the tick
/// after the last frame ends the animation and reports 0, `duration` after the first.
///
/// With Reduce Motion there is nothing to animate: the first phase is a plain hold of the
/// copied pose, and a single tick after `holdDuration` ends it, so the menu bar is not
/// redrawn 45 times with the same picture.
struct CopiedFlash: Sendable {
    static let frameRate = Design.Motion.menuBarFrameRate
    static let interval = 1 / frameRate
    static let duration = Design.Motion.menuBarCopy
    /// Ticks in one animation, counting the one that ends it.
    static let steps = Int((duration * frameRate).rounded()) + 1
    static let holdDuration = Design.Motion.menuBarHold
    /// Lets the system coalesce the timer by a fraction of a frame, never by a whole one.
    static let tolerance = interval / 8

    let reduceMotion: Bool
    private var ticks = 0

    init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    /// How often the timer driving this flash ticks.
    var timerInterval: TimeInterval { reduceMotion ? Self.holdDuration : Self.interval }

    mutating func restart() {
        ticks = 1
    }

    /// Advances one step and returns the phase to draw, 0 when the flash is over.
    mutating func tick() -> Int {
        guard ticks > 0 else { return 0 }
        let phase = ticks
        ticks = !reduceMotion && phase + 1 < Self.steps ? phase + 1 : 0
        return phase
    }

    /// Seconds into the animation at which phase `phase` is drawn; phase 1 is the start.
    static func time(phase: Int) -> TimeInterval {
        Double(max(0, phase - 1)) / frameRate
    }
}
