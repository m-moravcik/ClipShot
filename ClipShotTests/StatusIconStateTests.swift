import AppKit
import SwiftUI
import Testing
@testable import ClipShot

struct StatusIconStateTests {
    struct Case: Sendable {
        let copyEnabled: Bool
        let attention: Bool
        let flashing: Bool
        let expected: StatusIconState
    }

    static let cases: [Case] = [
        Case(copyEnabled: true, attention: false, flashing: false, expected: .idle),
        Case(copyEnabled: true, attention: false, flashing: true, expected: .copied),
        Case(copyEnabled: true, attention: true, flashing: false, expected: .attention),
        Case(copyEnabled: true, attention: true, flashing: true, expected: .attention),
        Case(copyEnabled: false, attention: false, flashing: false, expected: .paused),
        Case(copyEnabled: false, attention: false, flashing: true, expected: .copied),
        Case(copyEnabled: false, attention: true, flashing: false, expected: .attention),
        Case(copyEnabled: false, attention: true, flashing: true, expected: .attention),
    ]

    @Test(arguments: cases)
    func precedence(_ c: Case) {
        let attentions: [Attention] = c.attention ? [.couldNotCopy] : []
        #expect(StatusIconState.resolve(copyEnabled: c.copyEnabled, attentions: attentions,
                                        flashing: c.flashing) == c.expected)
    }

    @Test func everyStateHasALabel() {
        for state in StatusIconState.allCases {
            #expect(!String(localized: state.accessibilityLabel).isEmpty)
        }
    }

    /// The label as the menu bar gets it, at 2x.
    @MainActor
    private static func label(_ state: StatusIconState, phase: Int = 0, reduceMotion: Bool = false) throws -> CGImage {
        try #require(GlyphInk.menuBarImage(StatusIconArt(state: state, phase: phase, reduceMotion: reduceMotion)))
    }

    /// Pixels more than half covered in one image and not in the other.
    private static func difference(_ a: CGImage, _ b: CGImage) -> Int {
        func coverage(_ image: CGImage) -> [Bool] {
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] > 127 }
        }
        let ca = coverage(a), cb = coverage(b)
        guard ca.count == cb.count else { return .max }
        return zip(ca, cb).filter { $0 != $1 }.count
    }

    /// Each state reads without colour: every pair differs by a real share of the glyph,
    /// not a few pixels.
    @MainActor
    @Test func everyStateHasItsOwnSilhouette() throws {
        let images = try StatusIconState.allCases.map { try Self.label($0) }
        for i in images.indices {
            for j in images.indices where j > i {
                let d = Self.difference(images[i], images[j])
                #expect(d >= 60, "\(StatusIconState.allCases[i]) vs \(StatusIconState.allCases[j]): \(d) px")
            }
        }
    }

    /// The copy animation starts and ends on the idle picture, so nothing jumps when it
    /// starts or stops, and shows the copied pose (the check) in between.
    @MainActor
    @Test func copyAnimationStartsAndEndsAtRestAndShowsTheCheck() throws {
        let idle = try Self.label(.idle)
        #expect(Self.difference(try Self.label(.copied, phase: 1), idle) == 0, "first frame")
        #expect(Self.difference(try Self.label(.copied, phase: CopiedFlash.steps - 1), idle) == 0, "last frame")
        let copied = try Self.label(.copied)
        let held = (1..<CopiedFlash.steps).filter { phase in
            (try? Self.label(.copied, phase: phase)).map { Self.difference($0, copied) == 0 } ?? false
        }
        #expect(held.count >= 6, "the check holds for at least 0.2 s, frames \(held)")
        // Every frame in between moves: no two in a row stay identical outside the hold.
        let frames = try (1..<CopiedFlash.steps).map { try Self.label(.copied, phase: $0) }
        let changes = zip(frames, frames.dropFirst()).filter { Self.difference($0, $1) > 0 }.count
        #expect(changes >= frames.count / 2, "\(changes) of \(frames.count - 1) frames change")
    }

    /// Reduce Motion holds the copied pose in every phase.
    @MainActor
    @Test func reduceMotionHoldsTheCopiedPose() throws {
        let copied = try Self.label(.copied)
        for phase in 1..<CopiedFlash.steps {
            #expect(Self.difference(try Self.label(.copied, phase: phase, reduceMotion: true), copied) == 0, "phase \(phase)")
        }
    }

    /// The status item keeps its width through every state and frame.
    @MainActor
    @Test func sizeIsTheSameInEveryStateAndPhase() {
        var sizes: Set<String> = []
        for state in StatusIconState.allCases {
            for phase in 0...CopiedFlash.steps {
                for reduceMotion in [false, true] {
                    let view = NSHostingView(rootView: StatusIconArt(state: state, phase: phase, reduceMotion: reduceMotion))
                    sizes.insert("\(view.fittingSize)")
                }
            }
        }
        #expect(sizes == ["\(StatusIconArt.frame)"])
    }

    /// The menu bar scales a taller label down, which once made ClipShot look smaller than
    /// its siblings. The real label, drawn as the menu bar draws it (`GlyphInk.menuBarImage`),
    /// is never scaled and never clips a resting state: in every state its ink is the ink of
    /// the whole drawing (drawn with room to spare), within a pixel of anti-aliasing.
    @MainActor
    @Test func labelIsNeverScaledAndEverySymbolFitsIt() throws {
        #expect(StatusIconArt.frame.height <= StatusIconArt.menuBarHeight)
        let scale = GlyphInk.scale
        for state in StatusIconState.allCases {
            let image = try Self.label(state)
            #expect(CGFloat(image.height) == StatusIconArt.frame.height * scale, "\(state) label was scaled")
            #expect(CGFloat(image.width) == StatusIconArt.frame.width * scale)
            let whole = GlyphInk.size(try #require(GlyphInk.unclipped(Peg.pose(state), pad: 8)))
            let ink = GlyphInk.size(image)
            #expect(CGFloat(whole.width) <= StatusIconArt.frame.width * scale, "\(state): wider than the frame")
            #expect(CGFloat(whole.height) <= StatusIconArt.frame.height * scale, "\(state): taller than the frame")
            #expect(abs(ink.width - whole.width) <= 1, "\(state): \(ink.width) px wide, the drawing \(whole.width)")
            #expect(abs(ink.height - whole.height) <= 1, "\(state): \(ink.height) px tall, the drawing \(whole.height)")
        }
    }

    /// Optical size against the siblings, each drawn as the menu bar draws it, 1 px of
    /// anti-aliasing allowed:
    /// - idle is as tall as the taller sibling (VibeRes), so a smaller Peg fails here;
    /// - no wider than Eject Guard's drive, the widest sibling glyph;
    /// - its outline is as heavy as Eject Guard's.
    @MainActor
    @Test func idleGlyphMatchesTheSiblings() throws {
        let idleImage = try Self.label(.idle)
        let idle = GlyphInk.size(idleImage)
        let ejectGuardImage = try #require(GlyphInk.menuBarImage(GlyphInk.ejectGuardLabel()))
        let ejectGuard = GlyphInk.size(ejectGuardImage)
        let vibeRes = GlyphInk.size(try #require(GlyphInk.menuBarImage(GlyphInk.vibeResLabel())))
        let tallest = max(ejectGuard.height, vibeRes.height)
        #expect(idle.height >= tallest - 1, "idle \(idle.height) px, siblings \(ejectGuard.height) and \(vibeRes.height) px")
        #expect(idle.height <= tallest + 1, "idle \(idle.height) px, siblings \(ejectGuard.height) and \(vibeRes.height) px")
        #expect(idle.width <= ejectGuard.width + 1, "idle \(idle.width) px wide, Eject Guard \(ejectGuard.width) px")
        let stroke = GlyphInk.leftStroke(idleImage, atHeight: 0.75)
        let siblingStroke = GlyphInk.leftStroke(ejectGuardImage, atHeight: 0.75)
        #expect(stroke > 0 && abs(stroke - siblingStroke) <= 1, "outline \(stroke) px, Eject Guard \(siblingStroke) px")
    }
}
