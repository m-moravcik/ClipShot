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
/// Template image: only opacity varies, never colour. The copied state crossfades from
/// the idle symbol to the copied one by `phase` (see `CopiedFlash`).
///
/// Each state has its own outline, so it reads without colour and at a glance: the
/// capture corners (idle, the app icon's marquee and the Screenshot app's camera), a
/// circle (copied), a wide rounded rectangle (paused) and a triangle (attention).
struct StatusIconArt: View {
    let state: StatusIconState
    let phase: Int
    var reduceMotion = false

    static let glyphSize: CGFloat = 15
    /// Wide enough for the widest symbol (`pause.rectangle`, 21.5 pt at 15 pt), so the
    /// status item never changes width between states and nothing beside it shifts.
    static let frame = CGSize(width: 22, height: 18)

    nonisolated static func symbol(for state: StatusIconState) -> String {
        switch state {
        case .idle: "camera.viewfinder"
        case .copied: "checkmark.circle"
        case .paused: "pause.rectangle"
        case .attention: "exclamationmark.triangle"
        }
    }

    var body: some View {
        let copied = state == .copied
        let o = CopiedFlash.opacity(phase: phase, reduceMotion: reduceMotion)
        ZStack {
            Image(systemName: Self.symbol(for: copied ? .idle : state))
                .opacity(copied ? 1 - o : 1)
            if copied {
                Image(systemName: Self.symbol(for: .copied)).opacity(o)
            }
        }
        .font(.system(size: Self.glyphSize))
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
