#if DEBUG
import AppKit
import SwiftUI

/// Every frame of each of Peg's moments, on a light and a dark menu bar, at 2x: the copy
/// ending on the picture, on the dashed card (copying paused meanwhile) and on "!" (a problem
/// that does not stop copying), and the attention swing, pause and resume. Written by the
/// render harness as `menubar-moments.png`, and frame by frame into `peg-frames/` for GIFs.
struct MenuBarMomentsSheet: View {
    struct Play: Identifiable {
        let id: String
        let title: String
        let moment: PegMoment
        let from: StatusIconState
        let to: StatusIconState

        func pose(phase: Int) -> Peg.Pose {
            Peg.pose(rest: to, moment: moment, phase: phase, from: from, reduceMotion: false)
        }

        /// Every frame, then the resting pose the timer stops on.
        var poses: [Peg.Pose] {
            (1..<moment.steps).map { pose(phase: $0) } + [pose(phase: 0)]
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
    ]

    static let scale: CGFloat = 2
    private static let column: CGFloat = 30
    private static let bars: [(name: String, background: Color, glyph: Color)] = [
        ("light", Color(white: 0.95), .black), ("dark", Color(white: 0.12), .white),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Peg's moments, every frame at \(Int(PegFlash.frameRate)) fps, 2x; the last cell is the resting pose the timer stops on. Reduce Motion plays none of them (the copy is a held copied pose).")
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

    /// One PNG per frame, Peg four times its size on each menu bar, for the GIFs.
    static func writeFrames(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for play in plays {
            for bar in bars {
                for (index, pose) in play.poses.enumerated() {
                    let renderer = ImageRenderer(content: ZStack {
                        bar.background
                        StatusIconArt(pose: pose).foregroundStyle(bar.glyph)
                    }
                    .frame(width: 36, height: 24))
                    renderer.scale = 4
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    else { ScreenshotHarness.fail("peg frame render failed") }
                    let name = String(format: "%@-%@-%03d.png", play.id, bar.name, index)
                    try png.write(to: directory.appendingPathComponent(name))
                }
            }
        }
        print("wrote \(directory.path)")
    }
}
#endif
