import SwiftUI

/// What the menu bar icon is saying right now.
enum StatusIconState: Equatable, CaseIterable, Sendable {
    case idle, copied, paused, attention

    /// attention > copied > paused > idle.
    static func resolve(copyEnabled: Bool, attentions: [Attention], flashing: Bool) -> StatusIconState {
        if !attentions.isEmpty { return .attention }
        if flashing { return .copied }
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
/// (attention). While copied, `phase` picks the frame of the copy animation
/// (`CopiedFlash`); with Reduce Motion the copied pose is held as is.
///
/// One template image per pose: the label stays a plain `Image`, which a MenuBarExtra
/// draws as is, tinted like any template image.
struct StatusIconArt: View {
    let state: StatusIconState
    let phase: Int
    var reduceMotion = false

    /// The tallest label the menu bar draws at its own size. MenuBarExtra rasterises a label
    /// that is more than a plain `Image` and scales it down proportionally to this height:
    /// a 22 x 18 pt label came out at 16/18 of its size (measured on a real menu bar
    /// capture, macOS 27, 2026-10-19).
    static let menuBarHeight: CGFloat = 16
    /// Peg's canvas: no taller than `menuBarHeight`, so nothing scales the glyph down, and
    /// the same in every state and frame, so the status item never changes width.
    static let frame = Peg.canvas

    var pose: Peg.Pose { Peg.pose(state: state, phase: phase, reduceMotion: reduceMotion) }

    var body: some View {
        Image(nsImage: Peg.image(pose))
            .renderingMode(.template)
            .frame(width: Self.frame.width, height: Self.frame.height)
    }
}

/// The MenuBarExtra label.
struct StatusIcon: View {
    let state: StatusIconState
    let phase: Int
    var reduceMotion = false

    var body: some View {
        StatusIconArt(state: state, phase: phase, reduceMotion: reduceMotion)
            .accessibilityLabel(Text(state.accessibilityLabel))
    }
}
