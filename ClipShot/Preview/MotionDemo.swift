#if DEBUG
import AppKit
import SwiftUI

/// Development stage for reviewing motion live: the real views, on two `DemoScene`s with
/// real timers, play a scripted sequence in one window, so a screen recording shows what the
/// render harness's still frames cannot (springs, symbol effects, Peg's moments in step with
/// the tour and the preview). Debug builds only; `scripts/motion-demo.sh` runs it.
///
/// Like the harness, nothing here touches the user's screenshot settings, folder, clipboard
/// or preferences: the scenes are demo data in a scratch folder. The window floats at the top
/// left of the main screen, so a recording can be cropped to it, and the app quits at the end.
///
/// `CLIPSHOT_MOTION_DEMO=light|dark` picks the appearance; `CLIPSHOT_MOTION_REDUCE=1` plays
/// Peg's side as with Reduce Motion on (the views read the system setting itself, which
/// SwiftUI does not let a demo override).
@MainActor
enum MotionDemo {
    static let environmentKey = "CLIPSHOT_MOTION_DEMO"
    static let reduceKey = "CLIPSHOT_MOTION_REDUCE"

    static var requested: ColorScheme? {
        switch ProcessInfo.processInfo.environment[environmentKey] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    static var reduceMotion: Bool { ProcessInfo.processInfo.environment[reduceKey] == "1" }

    /// The beats of the script, in seconds from the window appearing.
    enum Cue {
        static let startCopying = 2.0
        static let firstCopy = 5.0
        static let hover = 7.0
        static let swipe = 7.8
        static let secondDisplay = 10.0
        static let trashRow = 10.5
        static let undo = 12.5
        static let attention = 14.5
        static let fixed = 17.0
        static let pause = 18.5
        static let resume = 20.0
        static let secondCopy = 22.0
        static let trashAgain = 23.0
        static let nextStep = 25.5
        static let undoOver = 28.0
        static let end = 30.5
    }

    static func run(_ scheme: ColorScheme) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        let scratch = (ScreenshotHarness.requestedScratch ?? FileManager.default.temporaryDirectory)
            .resolvingSymlinksInPath()
            .appendingPathComponent("ClipShotMotion-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let reduce = reduceMotion
            let tour = try DemoScene(in: scratch, onboardingShown: false, liveMotion: true, reduceMotion: reduce)
            let popover = try DemoScene(in: scratch, liveMotion: true, reduceMotion: reduce, trashInHome: true)
            try ScreenshotHarness.awaitTask { try await popover.recentScreenshots() }
            guard popover.start() else { ScreenshotHarness.fail("the demo folder was not watched") }
            DemoScene.wait { popover.model.recent.count == RecentScreenshots.count }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1160, height: 600), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.title = "ClipShot motion demo"
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.level = .floating
            window.contentView = NSHostingView(rootView: Stage(tour: tour.model, popover: popover.model, scheme: scheme))
            if let screen = NSScreen.screens.first {
                window.setFrameTopLeftPoint(NSPoint(x: screen.frame.minX, y: screen.visibleFrame.maxY))
            }
            window.orderFrontRegardless()

            let start = Date()
            func at(_ cue: TimeInterval) {
                let wait = start.addingTimeInterval(cue).timeIntervalSinceNow
                if wait > 0 { DemoScene.settle(wait) }
            }

            at(Cue.startCopying)
            advance()
            at(Cue.firstCopy)
            let first = try tour.shoot(DemoContent.screenshotName, image: DemoContent.screenshotPNG)
            // The pointer, through the preview's own handlers: hover, then a swipe held past
            // the dismiss point, brought back and let go, so the card springs back.
            at(Cue.hover)
            if let card = previewInteraction(in: window.contentView) {
                card.mouseEntered(with: mouse(.mouseEntered, card, dx: 0, in: window))
                at(Cue.swipe)
                card.mouseDown(with: mouse(.leftMouseDown, card, dx: 0, in: window))
                let width = card.bounds.width - 2 * PreviewCardMetrics.hoverOverhang
                for step in 1...24 {
                    let share = step <= 12 ? 0.5 * Double(step) / 12 : 0.5 - 0.35 * Double(step - 12) / 12
                    card.mouseDragged(with: mouse(.leftMouseDragged, card, dx: width * share, in: window))
                    DemoScene.settle(step == 12 ? 0.8 : 0.04)
                }
                card.mouseUp(with: mouse(.leftMouseUp, card, dx: width * 0.15, in: window))
                DemoScene.settle(0.5)
                card.mouseExited(with: mouse(.mouseExited, card, dx: 0, in: window))
            }
            at(Cue.secondDisplay)
            tour.model.previews.addExtraDisplay(CaptureFile(
                url: first.url.deletingPathExtension().appendingPathExtension("2.png"),
                created: first.created.addingTimeInterval(0.01), modified: first.modified,
                size: first.size, resourceID: Data(), isScreenshot: true))
            at(Cue.trashRow)
            try moveToTrash(popover, popover.model.recent[1])
            at(Cue.undo)
            try ScreenshotHarness.awaitTask { await popover.model.putBack() }
            at(Cue.attention)
            tour.prefs["target"] = "clipboard"
            popover.prefs["target"] = "clipboard"
            tour.model.refreshStatus()
            popover.model.refreshStatus()
            at(Cue.fixed)
            tour.prefs["target"] = "file"
            popover.prefs["target"] = "file"
            tour.model.refreshStatus()
            popover.model.refreshStatus()
            at(Cue.pause)
            tour.preferences.copyEnabled = false
            at(Cue.resume)
            tour.preferences.copyEnabled = true
            at(Cue.secondCopy)
            _ = try tour.shoot("Screenshot 2026-10-20 at 09.42.10.png", image: DemoContent.screenshotPNG(variant: 2))
            at(Cue.trashAgain)
            try moveToTrash(popover, popover.model.recent[2])
            at(Cue.nextStep)
            advance()
            // The Undo ends (as its 5 s would): the strip closes, the rows below move up and
            // the older screenshot fades in on the last row.
            at(Cue.undoOver)
            popover.model.showUndoForHarness(nil)
            at(Cue.end)
            tour.stop()
            popover.stop()
        } catch {
            ScreenshotHarness.fail("\(error)")
        }
        exit(0)
    }

    /// Tells the tour to press its prominent button, as a click would.
    static let advanceTour = Notification.Name("ClipShotMotionDemoAdvanceTour")

    private static func advance() {
        NotificationCenter.default.post(name: advanceTour, object: nil)
    }

    /// The floating preview's pointer handling: the one card interaction that swipes.
    private static func previewInteraction(in view: NSView?) -> CardInteractionView? {
        guard let view else { return nil }
        if let card = view as? CardInteractionView, card.onSwipeChanged != nil { return card }
        for child in view.subviews {
            if let card = previewInteraction(in: child) { return card }
        }
        return nil
    }

    /// A pointer event `dx` points right of the card's centre, in window coordinates.
    private static func mouse(_ type: NSEvent.EventType, _ card: NSView, dx: CGFloat, in window: NSWindow) -> NSEvent {
        let centre = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
        let point = NSPoint(x: centre.x + dx, y: centre.y)
        let time = ProcessInfo.processInfo.systemUptime
        if type == .mouseEntered || type == .mouseExited {
            return NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Move to Trash as a row asks for it, through the real path into the demo home's Trash
    /// folder, so Peg lets the picture go and Undo puts it back through the real path too.
    private static func moveToTrash(_ scene: DemoScene, _ file: CaptureFile) throws {
        try ScreenshotHarness.awaitTask { await scene.model.moveToTrash(file) }
    }

    /// Everything side by side: the menu bar (and Peg three times larger) of the tour and of
    /// the everyday popover (its Move to Trash and Undo), the tour, the everyday popover and
    /// the floating preview.
    private struct Stage: View {
        let tour: AppModel
        let popover: AppModel
        let scheme: ColorScheme

        var body: some View {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    menuBar("Menu bar", tour)
                    menuBar("Popover's", popover)
                }
                .frame(width: 90, alignment: .leading)
                panel { OnboardingView(tour: WelcomeTour(step: .folder)).environment(tour) }
                panel { MenuContent().environment(popover) }
                PreviewStack(previews: tour.previews, files: .model(tour))
                    .frame(width: 280, height: 480)
            }
            .padding(20)
            .frame(width: 1160, height: 600, alignment: .topLeading)
            .background(scheme == .dark ? Color(white: 0.1) : Color(white: 0.86))
            .environment(SettingsRouter())
            .environment(UpdateStatus())
            .environment(\.colorScheme, scheme)
        }

        private func menuBar(_ title: String, _ model: AppModel) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                caption(title)
                StatusIconArt(pose: model.iconPose)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                caption("Peg, 3x")
                Image(nsImage: Peg.image(model.iconPose, scale: 3))
                    .renderingMode(.template)
            }
        }

        private func caption(_ text: String) -> some View {
            Text(verbatim: text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }

        private func panel(@ViewBuilder _ content: () -> some View) -> some View {
            content()
                .frame(width: Design.Layout.popoverWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(scheme == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.95, green: 0.95, blue: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif
