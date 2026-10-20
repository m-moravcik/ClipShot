import SwiftUI

/// What the menu bar icon is saying right now.
enum StatusIconState: Equatable, CaseIterable, Sendable {
    case idle, copied, paused, attention

    /// copied > attention > paused > idle: a copy that lands while something needs
    /// attention still says Copied for its animation, then the icon returns to "!".
    static func resolve(copyEnabled: Bool, attentions: [Attention], flashing: Bool) -> StatusIconState {
        if flashing { return .copied }
        if !attentions.isEmpty { return .attention }
        return copyEnabled ? .idle : .paused
    }

    var accessibilityLabel: LocalizedStringResource {
        switch self {
        case .idle: Copy.StatusItem.idle
        case .copied: Copy.StatusItem.copied
        case .paused: Copy.StatusItem.paused
        case .attention: Copy.StatusItem.attention
        }
    }
}

/// The drawing, with nothing to observe, so it can be rendered offscreen and reviewed.
///
/// ClipShot's own symbol, `Peg`: a picture pegged on a line. Each state has its own
/// silhouette, so it reads without colour and at a glance: the picture (idle), a solid card
/// with a check (copied), a dashed empty card (paused) and a tilted card with "!"
/// (attention). While one of Peg's moments plays, the pose is its current frame
/// (`PegFlash`); with Reduce Motion the copied pose is held as is and nothing else moves.
///
/// One template image per pose: the label stays a plain `Image`, which a MenuBarExtra
/// draws as is, tinted like any template image.
struct StatusIconArt: View {
    let pose: Peg.Pose

    /// The tallest label the menu bar draws at its own size. MenuBarExtra rasterises a label
    /// that is more than a plain `Image` and scales it down proportionally to this height:
    /// a 22 x 18 pt label came out at 16/18 of its size (measured on a real menu bar
    /// capture, macOS 27, 2026-10-19).
    static let menuBarHeight: CGFloat = 16
    /// Peg's canvas: no taller than `menuBarHeight`, so nothing scales the glyph down, and
    /// the same in every state and frame, so the status item never changes width.
    static let frame = Peg.canvas

    init(pose: Peg.Pose) {
        self.pose = pose
    }

    /// A resting state, or a frame of the copy animation from the picture to the picture.
    init(state: StatusIconState, phase: Int = 0, reduceMotion: Bool = false) {
        pose = Peg.pose(state: state, phase: phase, reduceMotion: reduceMotion)
    }

    var body: some View {
        Image(nsImage: Peg.image(pose))
            .renderingMode(.template)
            .frame(width: Self.frame.width, height: Self.frame.height)
    }
}

/// The MenuBarExtra label: `pose` is what it draws (a frame of a moment while one plays),
/// `state` what VoiceOver reads.
struct StatusIcon: View {
    let state: StatusIconState
    let pose: Peg.Pose

    var body: some View {
        StatusIconArt(pose: pose)
            .accessibilityLabel(Text(state.accessibilityLabel))
    }
}
