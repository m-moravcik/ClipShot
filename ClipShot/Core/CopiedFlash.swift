import Foundation

/// Phase counter for the "screenshot copied" flash in the menu bar icon.
///
/// A MenuBarExtra label is a static image, so the icon is redrawn by a timer that calls
/// `tick()` every `interval` seconds. Phase 0 is off, 1-3 fade in, 4-11 hold, 12-15 fade
/// out. The 15th tick is the end of the flash and reports 0.
///
/// With Reduce Motion there is nothing to animate: the first phase is a plain hold, and a
/// single tick after `holdDuration` ends it, so the menu bar is not redrawn 14 times with
/// the same picture.
struct CopiedFlash: Sendable {
    static let steps = 15
    static let interval = 0.1
    /// The whole flash, `interval` times the 14 phases after the first.
    static let holdDuration = 1.4

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

    /// Opacity of the copied symbol. With Reduce Motion it is on or off, no fades.
    static func opacity(phase: Int, reduceMotion: Bool = false) -> Double {
        guard phase > 0, phase < steps else { return 0 }
        if reduceMotion { return 1 }
        switch phase {
        case 1...3: return eased(Double(phase) / 4)
        case 4...11: return 1
        default: return eased(1 - Double(phase - 11) / 4)
        }
    }

    /// Eject Guard's breath curve: 0.5 - 0.5 cos(pi u), 0 at u = 0 and 1 at u = 1.
    private static func eased(_ u: Double) -> Double {
        0.5 - 0.5 * cos(Double.pi * u)
    }
}
