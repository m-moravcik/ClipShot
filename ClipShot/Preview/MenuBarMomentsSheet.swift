#if DEBUG
import AppKit
import SwiftUI

/// Every frame of each of Peg's moments, on a light and a dark menu bar, at 2x: the copy
/// ending on the picture, on the dashed card (copying paused meanwhile) and on "!" (a problem
/// that does not stop copying), the attention swing, pause and resume, Move to Trash's
/// release, Undo's grip and the squeeze of the click that opens the popover, and moments that
/// replace one still playing (from the pose on show). Written by the render harness as
/// `menubar-moments.png`, and frame by frame into `peg-frames/` for GIFs.
struct MenuBarMomentsSheet: View {
    struct Play: Identifiable {
        let id: String
        let title: String
        let moment: PegMoment
        let from: StatusIconState
        let to: StatusIconState
        /// Replaces this moment at this phase, from the pose on show then.
        var replacing: (moment: PegMoment, phase: Int)?

        func pose(phase: Int) -> Peg.Pose {
            Peg.pose(rest: to, moment: moment, phase: phase, from: from, reduceMotion: false, handoff: handoff)
        }

        private var handoff: Peg.Pose? {
            replacing.map { Peg.pose(rest: to, moment: $0.moment, phase: $0.phase, from: from, reduceMotion: false) }
        }

        /// Every frame (the replaced moment's up to the hand-off first), then the resting pose
        /// the timer stops on.
        var poses: [Peg.Pose] {
            let before = replacing.map { r in
                (1..<r.phase).map { Peg.pose(rest: to, moment: r.moment, phase: $0, from: from, reduceMotion: false) }
            } ?? []
            return before + (1..<moment.steps).map { pose(phase: $0) } + [pose(phase: 0)]
        }
    }

    static let plays: [Play] = [
        Play(id: "copy", title: "Copy", moment: .copied, from: .idle, to: .idle),
        Play(id: "copy-paused", title: "Copy, paused meanwhile", moment: .copied, from: .idle, to: .paused),
        Play(id: "copy-attention", title: "Copy while something needs attention", moment: .copied,
             from: .attention, to: .attention),
        Play(id: "attention", title: "Something first needs attention", moment: .attention, from: .idle, to: .attention),
        Play(id: "pause", title: "Copy to clipboard off", moment: .pause, from: .idle, to: .paused),
        Play(id: "resume", title: "Copy to clipboard on", moment: .resume, from: .paused, to: .idle),
        Play(id: "release", title: "Move to Trash", moment: .release, from: .idle, to: .idle),
        Play(id: "release-paused", title: "Move to Trash while paused", moment: .release, from: .paused, to: .paused),
        Play(id: "grip", title: "Undo", moment: .grip, from: .idle, to: .idle),
        Play(id: "squeeze", title: "Click that opens the popover", moment: .squeeze, from: .idle, to: .idle),
        Play(id: "release-over-copy", title: "Move to Trash during the copy (the latest wins)", moment: .release,
             from: .idle, to: .idle, replacing: (.copied, 30)),
        Play(id: "copy-over-release", title: "Copy during a release (from the falling card)", moment: .copied,
             from: .idle, to: .idle, replacing: (.release, 8)),
        Play(id: "grip-over-release", title: "Undo during a release", moment: .grip, from: .idle, to: .idle,
             replacing: (.release, 12)),
        Play(id: "attention-over-grip", title: "Attention during an Undo's grip", moment: .attention,
             from: .idle, to: .attention, replacing: (.grip, 10)),
    ]

    static let scale: CGFloat = 2
    private static let column: CGFloat = 30
    private static let bars: [(name: String, background: Color, glyph: Color)] = [
        ("light", Color(white: 0.95), .black), ("dark", Color(white: 0.12), .white),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Peg's moments, every frame at \(Int(PegFlash.frameRate)) fps, 2x; the last cell is the resting pose the timer stops on. Reduce Motion: the copy, a release and a grip hold one pose; the others play nothing.")
                .font(.system(size: 12, weight: .semibold))
            ForEach(Self.plays) { play in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(play.title) - \(String(format: "%.1f", play.moment.duration)) s")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(Self.bars, id: \.name) { bar in
                        HStack(spacing: 0) {
                            ForEach(Array(play.poses.enumerated()), id: \.offset) { _, pose in
                                StatusIconArt(pose: pose)
                                    .foregroundStyle(bar.glyph)
                                    .frame(width: Self.column, height: 22)
                            }
                        }
                        .background(bar.background)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    /// One PNG per frame on each menu bar, for the GIFs: Peg four times its size in
    /// `directory`, and at the menu bar's own 1x and 2x pixels in `directory`@1x and @2x
    /// (enlarge those without smoothing to judge them as the bar shows them).
    static func writeFrames(into directory: URL) throws {
        for (scale, suffix) in [(CGFloat(4), ""), (1, "@1x"), (2, "@2x")] {
            let target = directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            for play in plays {
                for bar in bars {
                    for (index, pose) in play.poses.enumerated() {
                        let renderer = ImageRenderer(content: ZStack {
                            bar.background
                            StatusIconArt(pose: pose).foregroundStyle(bar.glyph)
                        }
                        .frame(width: 36, height: 24))
                        renderer.scale = scale
                        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                        else { ScreenshotHarness.fail("peg frame render failed") }
                        let name = String(format: "%@-%@-%03d.png", play.id, bar.name, index)
                        try png.write(to: target.appendingPathComponent(name))
                    }
                }
            }
            print("wrote \(target.path)")
        }
    }
}
#endif
