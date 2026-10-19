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
        case .idle: "ClipShot, copying on"
        case .copied: "ClipShot, screenshot copied"
        case .paused: "ClipShot, copying paused"
        case .attention: "ClipShot, needs attention"
        }
    }
}

/// The drawing, with nothing to observe, so it can be rendered offscreen and reviewed.
/// Template image: only opacity varies, never colour. The copied state crossfades from
/// the idle symbol to the copied one by `phase` (see `CopiedFlash`).
struct StatusIconArt: View {
    let state: StatusIconState
    let phase: Int
    var reduceMotion = false

    private static let glyphSize: CGFloat = 15

    /// Placeholder symbols; the final art is chosen later.
    nonisolated static func symbol(for state: StatusIconState) -> String {
        switch state {
        case .idle: "camera.viewfinder"
        case .copied: "checkmark.circle"
        case .paused: "pause.circle"
        case .attention: "exclamationmark.triangle"
        }
    }

    var body: some View {
        let copied = state == .copied
        let o = CopiedFlash.opacity(phase: phase, reduceMotion: reduceMotion)
        ZStack {
            // Fixed frame so the icon never changes size between states.
            Image(systemName: Self.symbol(for: copied ? .idle : state))
                .opacity(copied ? 1 - o : 1)
            if copied {
                Image(systemName: Self.symbol(for: .copied)).opacity(o)
            }
        }
        .font(.system(size: Self.glyphSize))
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
