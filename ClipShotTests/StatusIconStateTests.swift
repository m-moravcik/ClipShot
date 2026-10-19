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
    /// siblings. The label stays within the height drawn at its own size, and every state's
    /// symbol fits the label at the glyph size, so none is clipped either.
    @MainActor
    @Test func labelIsNeverScaledAndEverySymbolFitsIt() throws {
        #expect(StatusIconArt.frame.height <= StatusIconArt.menuBarHeight)
        for state in StatusIconState.allCases {
            let renderer = ImageRenderer(content: Image(systemName: StatusIconArt.symbol(for: state))
                .font(.system(size: StatusIconArt.glyphSize)))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let ink = Self.inkSize(image)
            #expect(CGFloat(ink.width) <= StatusIconArt.frame.width * 2, "\(state) is \(ink.width) px wide")
            #expect(CGFloat(ink.height) <= StatusIconArt.frame.height * 2, "\(state) is \(ink.height) px tall")
            // The idle viewfinder drew 25 px tall in the menu bar before; siblings draw 24-27.
            if state == .idle { #expect(ink.height >= 28) }
        }
    }

    /// The bounding box of the drawn pixels.
    static func inkSize(_ image: CGImage) -> (width: Int, height: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1)
    }
}
