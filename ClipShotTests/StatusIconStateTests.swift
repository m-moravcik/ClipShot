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

    @Test func everyStateHasALabelAndASymbol() {
        for state in [StatusIconState.idle, .copied, .paused, .attention] {
            #expect(!String(localized: state.accessibilityLabel).isEmpty)
            #expect(!StatusIconArt.symbol(for: state).isEmpty)
        }
    }

    @Test func everySymbolExistsAndHasItsOwnShape() {
        let symbols = StatusIconState.allCases.map(StatusIconArt.symbol(for:))
        #expect(Set(symbols).count == StatusIconState.allCases.count)
        for name in symbols {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }

    /// The status item keeps its width through every state and flash phase.
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

    /// The menu bar scales a taller label down, which made ClipShot look smaller than its
    /// siblings. The real label, drawn as the menu bar draws it (`GlyphInk.menuBarImage`), is
    /// never scaled and never clips a symbol: in every state its ink is the ink of the bare
    /// symbol at the glyph size, within a pixel of anti-aliasing, and fits the frame.
    @MainActor
    @Test func labelIsNeverScaledAndEverySymbolFitsIt() throws {
        #expect(StatusIconArt.frame.height <= StatusIconArt.menuBarHeight)
        let scale = GlyphInk.scale
        for state in StatusIconState.allCases {
            // Copied at full strength: Reduce Motion's hold draws the check alone.
            let label = StatusIconArt(state: state, phase: state == .copied ? 1 : 0, reduceMotion: true)
            let image = try #require(GlyphInk.menuBarImage(label))
            #expect(CGFloat(image.height) == StatusIconArt.frame.height * scale, "\(state) label was scaled")
            #expect(CGFloat(image.width) == StatusIconArt.frame.width * scale)

            let renderer = ImageRenderer(content: Image(systemName: StatusIconArt.symbol(for: state))
                .font(.system(size: StatusIconArt.glyphSize)))
            renderer.scale = scale
            let bare = GlyphInk.size(try #require(renderer.cgImage))
            // The symbol itself, unclipped, fits the frame: the label's ink can only match it
            // when nothing of it was cut off.
            #expect(CGFloat(bare.width) <= StatusIconArt.frame.width * scale, "\(state): symbol wider than the frame")
            #expect(CGFloat(bare.height) <= StatusIconArt.frame.height * scale, "\(state): symbol taller than the frame")
            let ink = GlyphInk.size(image)
            #expect(abs(ink.width - bare.width) <= 1, "\(state): \(ink.width) px wide, the symbol \(bare.width)")
            #expect(abs(ink.height - bare.height) <= 1, "\(state): \(ink.height) px tall, the symbol \(bare.height)")
            #expect(CGFloat(ink.width) <= StatusIconArt.frame.width * scale)
            #expect(CGFloat(ink.height) <= StatusIconArt.frame.height * scale)
        }
    }

    /// The floor the scale-down once broke, derived from the sibling ClipShot is sized
    /// against (`GlyphInk.ejectGuardLabel`), with 1 px of anti-aliasing allowed:
    /// - the idle label, drawn as the menu bar draws it, is at least as tall as Eject Guard's
    ///   `externaldrive` drawn the same way;
    /// - it is as tall as ClipShot's own symbol drawn at Eject Guard's point size.
    /// A smaller glyph size, or a label the menu bar scales down, fails here.
    @MainActor
    @Test func idleGlyphIsAtLeastAsTallAsTheSiblings() throws {
        let idle = GlyphInk.size(try #require(GlyphInk.menuBarImage(StatusIconArt(state: .idle, phase: 0))))
        let sibling = GlyphInk.size(try #require(GlyphInk.menuBarImage(GlyphInk.ejectGuardLabel())))
        #expect(idle.height >= sibling.height - 1, "idle \(idle.height) px, Eject Guard \(sibling.height) px")
        // The symbol alone, as drawn at that size, before any menu bar fitting.
        let atSiblingSize = GlyphInk.size(try #require(GlyphInk.image(
            Image(systemName: StatusIconArt.symbol(for: .idle)).font(.system(size: GlyphInk.ejectGuardPointSize)))))
        #expect(idle.height >= atSiblingSize.height - 1,
                "idle \(idle.height) px, the same symbol at Eject Guard's size \(atSiblingSize.height) px")
    }
}
