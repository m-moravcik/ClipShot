#if DEBUG
import AppKit
import SwiftUI

/// Development check that Peg's moments reach the real status item, not only the label
/// view: a Debug build runs the real `MenuBarExtra` on a `DemoScene` model, opens its popover
/// by clicking its own status item button in-process, and records the button's image while
/// the popover is open and a Copy, a Move to Trash and an Undo play. `scripts/status-item-probe.sh`
/// runs it.
///
/// Nothing here looks at the screen: the image is the one the status item button holds (what
/// the menu bar draws), read in this process. Like the harness, it never touches this Mac's
/// screenshot settings, folder, clipboard or preferences: the model is demo data in a
/// scratch folder, and its Trash is a folder there too.
@MainActor
enum StatusItemProbe {
    static let environmentKey = "CLIPSHOT_STATUS_PROBE"

    static var requestedOutput: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Kept for the life of the process: the app's `MenuBarExtra` shows its model.
    private static var scene: DemoScene?

    /// The demo model the app shows instead of the real one.
    static func makeModel() -> AppModel {
        let scratch = (ScreenshotHarness.requestedScratch ?? FileManager.default.temporaryDirectory)
            .resolvingSymlinksInPath()
            .appendingPathComponent("ClipShotProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let scene = try DemoScene(in: scratch, liveMotion: true, trashInHome: true)
            self.scene = scene
            return scene.model
        } catch {
            ScreenshotHarness.fail("\(error)")
        }
    }

    /// Runs once the app has finished launching, then quits it.
    static func start(into output: URL) {
        Task { @MainActor in
            do {
                try await run(into: output)
            } catch {
                ScreenshotHarness.fail("\(error)")
            }
            exit(0)
        }
    }

    private struct Sample {
        let label: String
        let time: TimeInterval
        let moment: String
        let phase: Int
        let png: Data?
        let matchesModel: Bool
        /// The frame before the model's: the label is redrawn on the next display pass.
        let matchesPrevious: Bool
    }

    private static func run(into output: URL) async throws {
        guard let scene else { ScreenshotHarness.fail("no demo model") }
        let model = scene.model
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await scene.recentScreenshots()
        model.startWatching()
        guard await poll(timeout: 5, { model.recent.count == RecentScreenshots.count }) else {
            ScreenshotHarness.fail("the demo list did not fill")
        }
        guard let button = await poll(timeout: 5, { statusButton() }) else {
            ScreenshotHarness.fail("no status item button in this process")
        }
        var lines: [String] = []
        lines.append("button: \(type(of: button)), image \(button.image == nil ? "nil" : "set"), "
            + "subviews \(button.subviews.map { String(describing: type(of: $0)) })")

        var samples: [Sample] = []
        func sample(_ label: String, since start: Date) {
            let png = button.image.flatMap { render($0) }
            let expected = render(Peg.image(model.iconPose))
            let previous = model.flashPhase > 1 ? render(Peg.image(Peg.pose(
                rest: model.restingIconState, moment: model.flashMoment, phase: model.flashPhase - 1,
                from: model.flashFrom, reduceMotion: model.flashReduceMotion, handoff: model.flashHandoff))) : nil
            samples.append(Sample(
                label: label, time: Date().timeIntervalSince(start),
                moment: model.flashPhase > 0 ? "\(model.flashMoment)" : "rest", phase: model.flashPhase,
                png: png, matchesModel: png != nil && png == expected,
                matchesPrevious: png != nil && png == previous))
        }

        // The click that opens the popover: an accessibility press, else a mouse down and up
        // on the button through this app's event queue (the button has no target or action
        // to send; SwiftUI tracks the press itself).
        let shown = button.window.map { $0.frame.height > 0 && $0.occlusionState.contains(.visible) } ?? false
        lines.append("status item on screen: \(shown ? "yes" : "NO, hidden (a menu bar manager?)"), "
            + "window frame \(button.window.map { NSStringFromRect($0.frame) } ?? "none")")
        let click = Date()
        sample("before click", since: click)
        if !button.accessibilityPerformPress(), let window = button.window {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let down = event(.leftMouseDown) { NSApp.postEvent(down, atStart: false) }
            if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        }
        var opened = await poll(timeout: 2, { model.popoverVisible })
        var standIn: NSPanel?
        if opened {
            lines.append(String(format: "real popover open %.0f ms after the click", Date().timeIntervalSince(click) * 1_000))
        } else {
            // The MenuBarExtra opens its window only from an item on screen. A stand-in: the
            // popover's own view in a key panel of this app under the menu bar, which reports
            // its visibility through the same reader. It shows the label keeps being redrawn
            // while one of the app's windows is open and key, not the MenuBarExtra's own.
            lines.append("real popover did not open: STAND-IN popover window used")
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: Design.Layout.popoverWidth, height: 420),
                styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "ClipShot status item probe"
            panel.level = .statusBar
            panel.contentView = NSHostingView(rootView: MenuContent()
                .environment(model).environment(SettingsRouter()).environment(UpdateStatus()))
            if let screen = NSScreen.main {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 40,
                                                   y: screen.visibleFrame.maxY))
            }
            NSApp.activate()
            let shownAt = Date()
            panel.makeKeyAndOrderFront(nil)
            lines.append(String(format: "ordering in took %.0f ms; squeeze playing when it returned: %@",
                                Date().timeIntervalSince(shownAt) * 1_000,
                                model.flashPhase > 0 && model.flashMoment == .squeeze ? "yes" : "no"))
            standIn = panel
            opened = await poll(timeout: 2, { model.popoverVisible })
            lines.append(String(format: "stand-in reported open %.0f ms after it was ordered in (key %@)",
                                Date().timeIntervalSince(shownAt) * 1_000, panel.isKeyWindow ? "yes" : "no"))
        }
        lines.append("popover open: \(opened ? "yes" : "NO"); moment: \(model.flashPhase > 0 ? "\(model.flashMoment)" : "none")")
        for _ in 0..<8 {
            sample("after click", since: click)
            try await Task.sleep(for: .milliseconds(33))
        }
        try await Task.sleep(for: .milliseconds(400))

        // Copy from the second row, as its Copy pill does, with the popover open.
        let copy = Date()
        let row = model.recent[1]
        let copied = await model.copyAgain(file: row)
        lines.append("copy from a row: \(copied ? "copied" : "FAILED")")
        for _ in 0..<Int(PegMoment.copied.duration / 0.1) + 4 {
            sample("copy", since: copy)
            try await Task.sleep(for: .milliseconds(100))
        }

        // Move to Trash from a row, then Undo, with the popover open.
        let trash = Date()
        await model.moveToTrash(model.recent[2])
        for _ in 0..<Int(PegMoment.release.duration / 0.1) + 3 {
            sample("trash", since: trash)
            try await Task.sleep(for: .milliseconds(100))
        }
        let undo = Date()
        await model.putBack()
        for _ in 0..<Int(PegMoment.grip.duration / 0.1) + 3 {
            sample("undo", since: undo)
            try await Task.sleep(for: .milliseconds(100))
        }
        lines.append("popover still visible at the end: \(model.popoverVisible ? "yes" : "no")")
        standIn?.orderOut(nil)

        // Frames as the button held them, and a log of which moment each came from.
        var distinct: [Data] = []
        for (index, s) in samples.enumerated() {
            if let png = s.png {
                if !distinct.contains(png) { distinct.append(png) }
                try png.write(to: output.appendingPathComponent(String(format: "button-%03d-%@.png", index, s.label.replacingOccurrences(of: " ", with: "-"))))
            }
            lines.append(String(format: "%@ +%4.0f ms  %@ phase %d  button image %@  %@", s.label, s.time * 1_000,
                                s.moment, s.phase, s.png == nil ? "nil" : "frame \(distinct.firstIndex(of: s.png!) ?? -1)",
                                s.matchesModel ? "= model pose" : s.matchesPrevious ? "= model's previous frame" : "!= model pose"))
        }
        for label in ["after click", "copy", "trash", "undo"] {
            let frames = Set(samples.filter { $0.label == label }.compactMap(\.png))
            lines.append("\(label): \(frames.count) distinct button images")
        }
        lines.append("distinct button images in all: \(distinct.count)")
        let off = samples.filter { !$0.matchesModel && !$0.matchesPrevious }.count
        lines.append("samples neither the model's frame nor the one before: \(off) of \(samples.count)")
        let log = lines.joined(separator: "\n") + "\n"
        try Data(log.utf8).write(to: output.appendingPathComponent("probe.log"))
        print(log)
        model.stopWatching()
    }

    /// The status item button of this process's `MenuBarExtra`.
    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews {
            if let button = find(in: child) { return button }
        }
        return nil
    }

    /// The image drawn at 2x, black on clear, as PNG: two images compare equal when they draw
    /// the same pixels.
    private static func render(_ image: NSImage) -> Data? {
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func poll<T>(timeout: TimeInterval, _ value: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = value() { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return value()
    }

    private static func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        await poll(timeout: timeout, { condition() ? true : nil }) ?? false
    }
}
#endif
