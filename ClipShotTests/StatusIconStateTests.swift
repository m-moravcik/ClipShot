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
}
