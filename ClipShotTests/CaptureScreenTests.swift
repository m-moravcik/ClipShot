import CoreGraphics
import Foundation
import Testing
@testable import ClipShot

struct CaptureScreenTests {
    /// The spike's machine: built-in 1800x1169 main display, a 2560x1440 one to its right,
    /// tops aligned (Cocoa coordinates: y up from the main display's bottom).
    private let screens = [
        CGRect(x: 0, y: 0, width: 1800, height: 1169),
        CGRect(x: 1800, y: 1169 - 1440, width: 2560, height: 1440),
    ]

    @Test func captureScreenUsesGlobalRectThenMouseThenMain() throws {
        let onMain = CGPoint(x: 100, y: 100)
        let onSecond = CGPoint(x: 2000, y: 500)
        // The global rect wins over the pointer (top-left origin: (300, 300) is on the main display).
        #expect(CaptureScreen.index(
            captureRect: CGRect(x: 300, y: 300, width: 65, height: 49), screenFrames: screens,
            mouse: onSecond, mainIndex: 0) == 0)
        // A whole-display capture of the second display (spike F3 values).
        #expect(CaptureScreen.index(
            captureRect: CGRect(x: 1800, y: 0, width: 2560, height: 1440), screenFrames: screens,
            mouse: onMain, mainIndex: 0) == 1)
        // A selection across both: the display holding most of it.
        #expect(CaptureScreen.index(
            captureRect: CGRect(x: 1700, y: 100, width: 400, height: 100), screenFrames: screens,
            mouse: onMain, mainIndex: 0) == 1)
        // No rect, or one on no display: the screen with the pointer.
        #expect(CaptureScreen.index(captureRect: nil, screenFrames: screens, mouse: onSecond, mainIndex: 0) == 1)
        #expect(CaptureScreen.index(
            captureRect: CGRect(x: -5000, y: 0, width: 10, height: 10), screenFrames: screens,
            mouse: onSecond, mainIndex: 0) == 1)
        // Pointer off every screen: the main screen.
        #expect(CaptureScreen.index(
            captureRect: nil, screenFrames: screens, mouse: CGPoint(x: -1, y: -1), mainIndex: 1) == 1)
        #expect(CaptureScreen.index(captureRect: nil, screenFrames: [], mouse: onMain, mainIndex: nil) == nil)
    }

    @Test func readsTheGlobalRectAttribute() throws {
        let dir = try Fixtures.makeDir()
        let url = try Fixtures.write(named: "Screenshot.png", in: dir)
        #expect(CaptureScreen.globalRect(of: url) == nil)
        Fixtures.setxattr(CaptureScreen.globalRectAttribute, Fixtures.bplist([300, 300, 65, 49]), on: url)
        #expect(CaptureScreen.globalRect(of: url) == CGRect(x: 300, y: 300, width: 65, height: 49))
        Fixtures.setxattr(CaptureScreen.globalRectAttribute, Fixtures.bplist(["not", "a", "rect"]), on: url)
        #expect(CaptureScreen.globalRect(of: url) == nil)
    }
}
