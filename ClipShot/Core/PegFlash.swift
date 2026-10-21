import Foundation

/// A one-shot animation of the menu bar icon, Peg. Each has a job: the copy confirms a copy;
/// attention, pause and resume confirm a change of state where it shows; release, grip and
/// squeeze answer the user's own action (Move to Trash, Undo, the click that opens the
/// popover) in place. None loops, none repeats on its own.
enum PegMoment: Equatable, Sendable, CaseIterable {
    /// A copy landed: the new card is pegged up, shows a check, and turns into the card the
    /// icon rests on.
    case copied
    /// Something first needs attention: the card swings into the "!" pose.
    case attention
    /// Copying was switched off: the picture fades and the outline breaks into dashes.
    case pause
    /// Copying was switched back on: the outline joins up and the peg bites again.
    case resume
    /// A screenshot moved to the Trash from the popover or a preview: the jaws open, the card
    /// drops out and fades, the jaws close empty, and the resting card comes back. Never for
    /// retention or a cleanup.
    case release
    /// Undo of that move: a picture rises into the open jaws and Peg clamps.
    case grip
    /// The click on the icon that opens the popover: the handles squeeze, the jaws open a
    /// point, and Peg springs back.
    case squeeze

    var duration: TimeInterval {
        switch self {
        case .copied: Design.Motion.menuBarCopy
        case .attention: Design.Motion.menuBarAttention
        case .pause: Design.Motion.menuBarPause
        case .resume: Design.Motion.menuBarResume
        case .release: Design.Motion.menuBarRelease
        case .grip: Design.Motion.menuBarGrip
        case .squeeze: Design.Motion.menuBarSqueeze
        }
    }

    /// Whether this moment may replace `playing`, from the pose on show; otherwise it does
    /// not play. Among copy, release and grip the latest event wins: the user's own Move to
    /// Trash or Undo is fresher news than the copy before it, and trashing a screenshot right
    /// after it was copied is the common case. A change of state (attention, pause, resume)
    /// replaces anything but a copy, and never gives way to a release or a grip. The squeeze
    /// replaces only a squeeze; anything replaces it.
    func replaces(_ playing: PegMoment) -> Bool {
        switch self {
        case .copied: true
        case .attention, .pause, .resume: playing != .copied
        case .release, .grip: playing == .copied || playing == .release || playing == .grip || playing == .squeeze
        case .squeeze: playing == .squeeze
        }
    }

    /// With Reduce Motion: how long the moment's key pose is held, as one plain hold; nil for
    /// a moment that does not play at all (its state changes in one frame, or, for the
    /// squeeze, nothing shows).
    var reduceMotionHold: TimeInterval? {
        switch self {
        case .copied: Design.Motion.menuBarHold
        case .release: Design.Motion.menuBarRelease
        case .grip: Design.Motion.menuBarGrip
        case .attention, .pause, .resume, .squeeze: nil
        }
    }

    /// Ticks in one play, counting the one that ends it.
    var steps: Int { Int((duration * PegFlash.frameRate).rounded()) + 1 }
}

/// Phase counter for Peg's moments (`Peg.pose(rest:moment:phase:from:reduceMotion:)`).
///
/// A MenuBarExtra label is a static image, so the icon is redrawn by a timer that calls
/// `tick()` every `interval` seconds, and only while a moment plays. Phase 0 is off;
/// phases 1...`steps - 1` are the frames, phase `p` at `time(phase:)` seconds; the tick
/// after the last frame ends the moment and reports 0, `duration` after the first.
///
/// With Reduce Motion there is nothing to animate: the copy is a plain hold of the copied
/// pose, a release or a grip a plain hold of its key pose, and a single tick after the hold
/// (`PegMoment.reduceMotionHold`) ends it, so the menu bar is not redrawn frame after frame
/// with the same picture. The other moments do not play at all (the model never starts
/// them), so their state changes in one frame.
struct PegFlash: Sendable {
    static let frameRate = Design.Motion.menuBarFrameRate
    static let interval = 1 / frameRate
    /// The copy animation's length and ticks; the other moments are shorter.
    static let duration = PegMoment.copied.duration
    static let steps = PegMoment.copied.steps
    static let holdDuration = Design.Motion.menuBarHold
    /// Lets the system coalesce the timer by a fraction of a frame, never by a whole one.
    static let tolerance = interval / 8

    let moment: PegMoment
    let reduceMotion: Bool
    private var ticks = 0

    init(_ moment: PegMoment = .copied, reduceMotion: Bool = false) {
        self.moment = moment
        self.reduceMotion = reduceMotion
    }

    /// How often the timer driving this flash ticks.
    var timerInterval: TimeInterval {
        reduceMotion ? moment.reduceMotionHold ?? Self.holdDuration : Self.interval
    }

    var steps: Int { moment.steps }

    mutating func restart() {
        ticks = 1
    }

    /// Advances one step and returns the phase to draw, 0 when the moment is over.
    mutating func tick() -> Int {
        guard ticks > 0 else { return 0 }
        let phase = ticks
        ticks = !reduceMotion && phase + 1 < steps ? phase + 1 : 0
        return phase
    }

    /// Seconds into the moment at which phase `phase` is drawn; phase 1 is the start.
    static func time(phase: Int) -> TimeInterval {
        Double(max(0, phase - 1)) / frameRate
    }
}
