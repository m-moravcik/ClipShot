#if DEBUG
import AppKit
import SwiftUI

/// Development harness: renders the popover, its attention rows, the welcome tour, the
/// Settings panes, the menu bar icon in every state and the app icon to PNG, for the README
/// and the web.pexelo portfolio. Debug builds only; `scripts/screenshots.sh` drives it.
///
/// A MenuBarExtra popover cannot be opened programmatically, and a hand-taken screenshot
/// drifts from the app and carries whatever the author's Mac has. This renders the real views
/// against real `AppModel`s on invented data (`DemoScene`): a throwaway screenshot folder, a
/// dictionary for `com.apple.screencapture` and a pasteboard that never reaches the system.
/// Nothing here reads or writes the user's screenshot settings, clipboard or preferences.
///
/// The panels are captured through `NSHostingView.cacheDisplay`, not `ImageRenderer`: the
/// popover is full of AppKit-backed controls (switches, buttons, pickers) that
/// `ImageRenderer` leaves blank. Only scenery around a finished panel, and the menu bar
/// glyphs, go through `ImageRenderer`, since they are plain shapes, symbols and images.
@MainActor
enum ScreenshotHarness {
    static let environmentKey = "CLIPSHOT_SCREENSHOTS"

    /// The directory to write into, when the harness was asked for.
    static var requestedOutput: URL? {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func run(into output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Demo folders live in a scratch directory under the temporary directory, resolved so
        // every path the model compares has one spelling. Left for the OS to clean up.
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ClipShotScreenshots-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let shots = Shots(output: output)

            let icon = icon(pixels: 512)
            try shots.write(icon, "icon")
            try shots.write(render(MenuBarStatesSheet(), scale: MenuBarStatesSheet.scale), "menubar-states")
            try shots.write(render(MenuBarOpticalSheet(), scale: MenuBarOpticalSheet.scale), "menubar-optical-size")

            try renderMain(shots, scratch: scratch, icon: icon)
            try renderPaused(shots, scratch: scratch)
            try renderAttentions(shots, scratch: scratch)
            try renderFull(shots, scratch: scratch)
            try renderTour(shots, scratch: scratch)
            try renderPreviews(shots, scratch: scratch)
        } catch {
            fail("\(error)")
        }
        exit(0)
    }

    // MARK: Scenes

    /// The everyday popover: copying on, the screenshot just copied, a cleanup earlier today.
    /// Also the Settings panes and the hero and banner pictures.
    private static func renderMain(_ shots: Shots, scratch: URL, icon: NSBitmapImageRep) throws {
        let scene = try DemoScene(in: scratch)
        let now = Date()
        // Older screenshots ClipShot never saw: Settings offers to clean them up as well.
        try awaitTask { try await scene.oldScreenshots(3, days: 41, tracked: false) }
        // Earlier screenshots it saw: the strip under the card.
        try awaitTask { try await scene.recentScreenshots() }
        scene.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: ConfirmedFolder.of(scene.folder))
        // Today at 09:12, so the picture does not change with the time it is rendered.
        let cleanup = Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3_600 + 12 * 60)
        scene.preferences.lastRetention = RetentionResult(moved: 12, movedBytes: 38_400_000, failed: 0, at: cleanup)
        scene.preferences.totals = Totals(copied: 148, freedBytes: 1_640_000_000, trashed: 412)
        guard scene.start() else { fail("the demo folder was not watched") }
        try scene.copyDemoScreenshot()
        scene.model.refreshPreview()
        DemoScene.wait { scene.model.retentionPreview != nil }
        DemoScene.wait { scene.model.recent.count == RecentScreenshots.count }

        let updater = DemoUpdater()
        for scheme in ColorScheme.allCases {
            let popover = capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
            try shots.write(popover, "popover", scheme)
            try shots.write(render(HeroScene(popover: popover, scheme: scheme, banner: false)), "hero", scheme)
            try shots.write(render(HeroScene(popover: popover, scheme: scheme, banner: true, icon: image(icon))), "banner", scheme)

            for tab in SettingsTab.allCases {
                let window = capture(SettingsWindow(tab: tab, scheme: scheme)
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
                try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-\(tab.name)", scheme)
            }
        }
        // Just after Move to Trash on the strip's newest: Undo for 5 s, the gap closed. The
        // demo Trash refuses every move, so the file goes to a demo Trash folder by hand.
        if let moved = scene.model.recent.first {
            let trash = scene.home.appendingPathComponent(".Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let inTrash = trash.appendingPathComponent(moved.url.lastPathComponent)
            try FileManager.default.moveItem(at: moved.url, to: inTrash)
            scene.model.undoable = AppModel.TrashedScreenshot(file: moved, inTrash: inTrash)
            scene.model.screenshotLeft(moved)
            // The strip fills up again from the fifth earlier screenshot.
            DemoScene.wait { scene.model.recent.count == RecentScreenshots.count && !scene.model.recent.contains(moved) }
            DemoScene.settle(0.6)
            for scheme in ColorScheme.allCases {
                try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme), "popover-undo", scheme)
            }
            scene.model.undoable = nil
        }

        // General just after "Replay welcome tour": the tour waits in the popover.
        scene.model.replayOnboarding()
        for scheme in ColorScheme.allCases {
            let window = capture(SettingsWindow(tab: .general, scheme: scheme, replayed: true)
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-general-replayed", scheme)
        }
        scene.stop()
    }

    /// Copying switched off.
    private static func renderPaused(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        scene.preferences.copyEnabled = false
        scene.preferences.totals = Totals(copied: 148, freedBytes: 0, trashed: 0)
        guard scene.start() else { fail("the demo folder was not watched") }
        DemoScene.settle()
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), "popover-paused", scheme)
        }
        scene.stop()
    }

    /// The popover with several things to fix, and every attention row on its own.
    private static func renderAttentions(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        scene.prefs["target"] = "clipboard"
        scene.pasteboard.failing = true
        scene.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: nil)
        guard scene.start() else { fail("the demo folder was not watched") }
        _ = try scene.shoot(DemoContent.screenshotName, image: DemoContent.screenshotPNG)
        DemoScene.wait { scene.model.attentions.count == 3 }
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), "popover-attention", scheme)
            // The destination guard as Settings shows it, next to its fix.
            let window = capture(SettingsWindow(tab: .capture, scheme: scheme)
                .harnessEnvironment(scene.model), scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-capture-attention", scheme)
        }

        // The tour's Try it on a replayed tour, blocked by the top attention row.
        var blocked = WelcomeTour()
        blocked.advance(scene.model)
        for scheme in ColorScheme.allCases {
            try shots.write(capture(tourPanel(blocked, scheme: scheme).harnessEnvironment(scene.model), scheme: scheme),
                            "onboarding-2-try-attention", scheme)
        }

        let folder = scene.folder
        let rows: [(String, Attention)] = [
            ("destination", .destinationNotFile),
            ("folder-missing", .folderMissing(folder)),
            ("access-denied", .folderAccessDenied(folder)),
            ("could-not-copy", .couldNotCopy),
            ("retention-folder-changed", .retentionFolderChanged(folder)),
            ("no-trash", .noTrash(folder)),
        ]
        for scheme in ColorScheme.allCases {
            for (name, attention) in rows {
                let row = AttentionRow(attention: attention)
                    .padding(Design.Spacing.m)
                    .frame(width: Design.Layout.popoverWidth)
                try shots.write(capture(PopoverPanel(scheme: scheme, framed: false) { row }
                    .harnessEnvironment(scene.model), scheme: scheme), "attention-\(name)", scheme)
            }
        }
        scene.stop()
    }

    /// Every row the popover can show at once: an attention, the latest card and the strip,
    /// the Markup tip and the update card. Long translations take it past its height cap,
    /// where the middle scrolls under a fixed header and footer.
    private static func renderFull(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        scene.preferences.markupTipShown = false
        scene.preferences.totals = Totals(copied: 3, freedBytes: 1_640_000_000, trashed: 412)
        scene.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: ConfirmedFolder.of(scene.folder))
        // The strip too, so long translations meet the height cap with every row on show.
        try awaitTask { try await scene.recentScreenshots() }
        guard scene.start() else { fail("the demo folder was not watched") }
        try scene.copyDemoScreenshot()
        DemoScene.wait { scene.model.recent.count == RecentScreenshots.count }
        scene.prefs["target"] = "clipboard"
        DemoScene.wait { !scene.model.attentions.isEmpty }
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updateStatus: UpdateStatus(isUpdateReady: true)), scheme: scheme),
                "popover-full", scheme)
        }
        scene.stop()
    }

    /// The welcome tour, step by step, as a fresh install shows it.
    private static func renderTour(_ shots: Shots, scratch: URL) throws {
        let fresh = try DemoScene(in: scratch, onboardingShown: false)
        var steps: [(String, WelcomeTour, DemoScene)] = [
            ("1-welcome", WelcomeTour(), fresh),
            ("2-folder", WelcomeTour(step: .folder), fresh),
        ]

        // Step 2's Try it: waiting, then the screenshot it copied.
        let trying = try DemoScene(in: scratch, onboardingShown: false)
        var tour = WelcomeTour(step: .folder)
        tour.advance(trying.model)
        DemoScene.wait { trying.model.watchedFolder != nil }
        DemoScene.settle()
        for scheme in ColorScheme.allCases {
            try shots.write(capture(tourPanel(tour, scheme: scheme).harnessEnvironment(trying.model), scheme: scheme),
                            "onboarding-2-try-waiting", scheme)
        }
        try trying.copyDemoScreenshot()
        steps.append(("2-try-copied", tour, trying))

        // Step 3 with screenshots that would go now.
        let tidy = try DemoScene(in: scratch, onboardingShown: false)
        try awaitTask { try await tidy.oldScreenshots(12, days: 35, tracked: true) }
        guard tidy.start() else { fail("the demo folder was not watched") }
        tidy.model.refreshPreview()
        DemoScene.wait { tidy.model.retentionPreview != nil }
        steps.append(("3-tidy", WelcomeTour(step: .tidy), tidy))

        for scheme in ColorScheme.allCases {
            for (name, step, scene) in steps {
                try shots.write(capture(tourPanel(step, scheme: scheme).harnessEnvironment(scene.model), scheme: scheme),
                                "onboarding-\(name)", scheme)
            }
        }
        for scene in [fresh, trying, tidy] { scene.stop() }
    }

    /// ClipShot's floating preview (Addendum A2): one preview, the hover state, a stack of
    /// three with "+1" for a second display, the popover in Preview mode macOS, and key frames
    /// of the motion (A3), drawn from the same springs the app animates with.
    private static func renderPreviews(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        guard scene.start() else { fail("the demo folder was not watched") }
        DemoScene.wait { scene.model.previewMode == .clipShot }
        try scene.copyDemoScreenshot()
        DemoScene.wait { scene.model.previews.visible.count == 1 }
        guard let single = scene.model.previews.visible.first else { fail("no preview") }
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PreviewDesktop(scheme: scheme) { PreviewStack() }
                .harnessEnvironment(scene.model), scheme: scheme), "preview", scheme)
            try shots.write(capture(PreviewDesktop(scheme: scheme, height: PreviewCardMetrics.maxSize.height + PreviewCardMetrics.margin * 2 + 20) {
                PreviewCard(item: single, actions: .inert, hovering: true)
                    .padding(PreviewCardMetrics.screenInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }.harnessEnvironment(scene.model), scheme: scheme), "preview-hover", scheme)
        }

        // Three in a row, the newest a two-display capture.
        for index in 2...3 {
            _ = try scene.shoot(DemoContent.screenshotName.replacingOccurrences(of: ".png", with: " \(index).png"),
                                image: DemoContent.screenshotPNG)
            DemoScene.wait { scene.model.previews.visible.count == index }
        }
        if let newest = scene.model.previews.visible.last?.file {
            scene.model.previews.addExtraDisplay(CaptureFile(
                url: newest.url.deletingPathExtension().appendingPathExtension("2.png"),
                created: newest.created.addingTimeInterval(0.01), modified: newest.modified,
                size: newest.size, resourceID: Data(), isScreenshot: true))
        }
        DemoScene.settle(0.6)
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PreviewDesktop(scheme: scheme) { PreviewStack() }
                .harnessEnvironment(scene.model), scheme: scheme), "preview-stack", scheme)
        }

        // Settings > Capture with the Preview picker, and the popover in Preview mode macOS.
        let updater = DemoUpdater()
        scene.prefs["show-thumbnail"] = true
        DemoScene.wait { scene.model.previewMode == .macOS }
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme), "popover-macos-mode", scheme)
            let window = capture(SettingsWindow(tab: .capture, scheme: scheme)
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-capture-macos-mode", scheme)
        }
        scene.prefs["show-thumbnail"] = false
        DemoScene.wait { scene.model.previewMode == .clipShot }

        // An install from before Preview modes, the macOS thumbnail on: the one-time offer.
        let upgraded = try DemoScene(in: scratch)
        upgraded.preferences.previewModeApplied = false
        upgraded.prefs["show-thumbnail"] = true
        guard upgraded.start() else { fail("the demo folder was not watched") }
        DemoScene.wait { upgraded.model.showsPreviewOffer }
        try upgraded.copyDemoScreenshot()
        for scheme in ColorScheme.allCases {
            try shots.write(capture(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(upgraded.model, updater: updater), scheme: scheme), "popover-preview-offer", scheme)
        }
        upgraded.stop()

        for scheme in ColorScheme.allCases {
            try shots.write(capture(PreviewMotionSheet(item: single, scheme: scheme)
                .harnessEnvironment(scene.model), scheme: scheme), "preview-motion", scheme)
        }
        scene.stop()
    }

    /// The tour as `MenuContent` frames it.
    private static func tourPanel(_ tour: WelcomeTour, scheme: ColorScheme) -> some View {
        PopoverPanel(scheme: scheme) {
            OnboardingView(tour: tour)
                .frame(width: Design.Layout.popoverWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(.ultraThinMaterial)
        }
    }

    // MARK: Capture

    /// Lays the view out in an off-screen window and draws it at 2x.
    ///
    /// The window is ordered in (off-screen) and the run loop turned for a moment, so
    /// `onAppear` and `task` have run before the capture, exactly as they would in the popover.
    private static func capture(_ view: some View, scheme: ColorScheme) -> NSBitmapImageRep {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        hosting.appearance = appearance
        let window = HarnessWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()

        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        let size = hosting.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("could not allocate a bitmap") }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Renders plain SwiftUI (shapes, text, symbols, images) at 2x.
    static func render(_ view: some View, scale: CGFloat = 2) -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { fail("render failed") }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return rep
    }

    /// The app icon as the system draws it: the Icon Composer document compiled into this
    /// bundle, glass and all.
    private static func icon(pixels: Int) -> NSBitmapImageRep {
        let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("could not allocate a bitmap") }
        let points = CGFloat(pixels) / 2
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func image(_ rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Runs async demo setup to completion while the main run loop keeps turning.
    private static func awaitTask(_ work: @escaping @MainActor @Sendable () async throws -> Void) throws {
        let box = OutcomeBox()
        Task { @MainActor in
            do {
                try await work()
                box.outcome = .success(())
            } catch {
                box.outcome = .failure(error)
            }
        }
        DemoScene.wait(timeout: 10) { box.outcome != nil }
        guard let outcome = box.outcome else { fail("demo setup timed out") }
        try outcome.get()
    }

    @MainActor
    private final class OutcomeBox {
        var outcome: Result<Void, any Error>?
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("screenshots: \(message)\n".utf8))
        exit(1)
    }
}

/// Writes PNGs into the output directory, with the scheme as a suffix.
@MainActor
private struct Shots {
    let output: URL

    func write(_ rep: NSBitmapImageRep, _ name: String, _ scheme: ColorScheme? = nil) throws {
        let suffix = scheme.map { $0 == .dark ? "-dark" : "-light" } ?? ""
        let url = output.appendingPathComponent("\(name)\(suffix).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            ScreenshotHarness.fail("could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
        print("wrote \(url.path)  \(rep.pixelsWide)x\(rep.pixelsHigh) px")
    }
}

/// Draws its controls as they look in the frontmost window (blue switches, a blue default
/// button), although the harness app is never activated and so never takes focus from what
/// the user is doing. Off-screen, AppKit asks the window's key and main appearance; the two
/// selectors are not public API, which is acceptable in a Debug-only harness.
private final class HarnessWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    @objc(hasKeyAppearance) var harnessHasKeyAppearance: Bool { true }
    @objc(hasMainAppearance) var harnessHasMainAppearance: Bool { true }
}

private extension SettingsTab {
    static let allCases: [SettingsTab] = [.general, .capture, .retention, .about]

    var name: String {
        switch self {
        case .general: "general"
        case .capture: "capture"
        case .retention: "retention"
        case .about: "about"
        }
    }
}

private extension View {
    func harnessEnvironment(
        _ model: AppModel, updater: (any UpdaterProviding)? = nil, updateStatus: UpdateStatus = UpdateStatus()
    ) -> some View {
        environment(model)
            .environment(SettingsRouter())
            .environment(updateStatus)
            .environment(\.updater, updater)
    }
}

/// The popover's frame, as `MenuContent` sets it up.
///
/// The real popover sits on `.ultraThinMaterial` over the desktop, which an off-screen
/// window has nothing to blur. A solid fill in the material's resting colour keeps the
/// contrast what the eye sees.
private struct PopoverPanel<Content: View>: View {
    let scheme: ColorScheme
    /// False for a single row: no popover frame, just the row on the popover's colour.
    var framed = true
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if framed {
                content
                    .frame(width: Design.Layout.popoverWidth)
                    .frame(maxHeight: Design.Layout.popoverMaxHeight)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(scheme.popoverFill)
        .environment(\.colorScheme, scheme)
    }
}

private extension ColorScheme {
    var popoverFill: Color {
        self == .dark ? Color(red: 0.16, green: 0.16, blue: 0.17) : Color(red: 0.95, green: 0.95, blue: 0.96)
    }
}

/// A Settings window: the title and the toolbar of tabs as macOS draws them, around the real
/// pane. The window chrome is scenery; a `TabView` drawn off-screen leaves its tab bar
/// blank, so the tabs are drawn here from the same titles and symbols `SettingsView` uses.
private struct SettingsWindow: View {
    let tab: SettingsTab
    let scheme: ColorScheme
    /// General right after "Replay welcome tour".
    var replayed = false

    private var dark: Bool { scheme == .dark }

    private static let tabs: [(SettingsTab, LocalizedStringResource, String)] = [
        (.general, Copy.Tab.general, "gearshape"),
        (.capture, Copy.Tab.capture, "camera.viewfinder"),
        (.retention, Copy.Tab.retention, "trash"),
        (.about, Copy.Tab.about, "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ZStack {
                    HStack(spacing: 8) {
                        ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                                 Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                            Circle().fill(color).frame(width: 12, height: 12)
                        }
                        Spacer()
                    }
                    Text(Self.tabs.first { $0.0 == tab }?.1 ?? Copy.Tab.general)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 28)

                HStack(spacing: 4) {
                    ForEach(Self.tabs.indices, id: \.self) { index in
                        let item = Self.tabs[index]
                        VStack(spacing: 2) {
                            Image(systemName: item.2)
                                .font(.system(size: 18))
                                .frame(height: 22)
                            Text(item.1)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(item.0 == tab ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 64)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(item.0 == tab ? Color.primary.opacity(0.08) : Color.clear))
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .background(dark ? Color(white: 0.17) : Color(white: 0.965))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            }

            pane
                .frame(width: Design.Layout.settingsSize.width, height: Design.Layout.settingsSize.height)
                .background(dark ? Color(white: 0.13) : Color(white: 0.98))
        }
        .frame(width: Design.Layout.settingsSize.width)
        .environment(\.colorScheme, scheme)
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralSettings(replayRequested: replayed)
        case .capture: CaptureSettingsPane()
        case .retention: RetentionSettings()
        case .about: AboutSettings()
        }
    }
}

/// The bottom-right corner of a desktop, the size of the preview panel: the right and bottom
/// edges of the picture are the edges of the screen's visible frame.
private struct PreviewDesktop<Content: View>: View {
    let scheme: ColorScheme
    var height = PreviewPanelController.panelSize.height
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: PreviewPanelController.panelSize.width + 120, height: height)
            .background(DesktopFill(scheme: scheme))
            .environment(\.colorScheme, scheme)
    }
}

private struct DesktopFill: View {
    let scheme: ColorScheme

    var body: some View {
        LinearGradient(colors: scheme == .dark
                       ? [Color(red: 0.24, green: 0.09, blue: 0.10), Color(red: 0.27, green: 0.16, blue: 0.05)]
                       : [Color(red: 0.99, green: 0.84, blue: 0.80), Color(red: 0.99, green: 0.91, blue: 0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Key frames of the preview's motion, computed from `Design.Motion`'s springs and curves:
/// arrival from the screen edge (with the image landing), a swipe flung away, Move to Trash,
/// and an older preview sliding up when a new one arrives. Times in ms under each frame.
private struct PreviewMotionSheet: View {
    let item: PreviewItem
    let scheme: ColorScheme

    private struct Frame: Identifiable {
        let id: Int
        let time: Double
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var opacity: Double = 1
        var imageScale: CGFloat = 1
    }

    private var size: CGSize { PreviewCardMetrics.size(for: item.image) }
    private var cell: CGSize { CGSize(width: size.width + 40, height: size.height + 64) }
    private static let times: [Double] = [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.45]

    private var arrival: [Frame] {
        let travel = size.width + PreviewCardMetrics.screenInset + 20
        return Self.times.enumerated().map { index, t in
            let p = Design.Motion.arriveSpring.value(target: 1.0, time: t)
            let land = Design.Motion.landSpring.value(target: 1.0, time: max(0, t - Design.Motion.landDelay))
            return Frame(id: index, time: t, x: (1 - p) * travel,
                         imageScale: PreviewCard.arrivalImageScale + (1 - PreviewCard.arrivalImageScale) * land)
        }
    }

    private var fling: [Frame] {
        let start: CGFloat = 50, target = size.width + PreviewCardMetrics.screenInset + PreviewCardMetrics.margin
        let velocity = Design.Motion.flingVelocity(1_200, distance: target - start)
        return Self.times.enumerated().map { index, t in
            let p = Design.Motion.flingSpring.value(target: 1.0, initialVelocity: velocity, time: t)
            return Frame(id: index, time: t, x: start + (target - start) * p)
        }
    }

    private var trash: [Frame] {
        Self.times.enumerated().map { index, t in
            let q = UnitCurve.easeIn.value(at: min(1, t / Design.Motion.dropDuration))
            return Frame(id: index, time: t, y: 36 * q, scale: 1 - 0.65 * q, opacity: 1 - q)
        }
    }

    private var stackUp: [Frame] {
        let rise = size.height + PreviewCardMetrics.spacing
        return Self.times.enumerated().map { index, t in
            let p = Design.Motion.stackSpring.value(target: 1.0, time: t)
            return Frame(id: index, time: t, y: -rise * p * 0.35)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Arrival (arrive + land)", arrival, edge: true)
            row("Swipe fling at 1200 pt/s", fling, edge: true)
            row("Move to Trash (drop)", trash, edge: false)
            row("Stack: older preview moves up (scaled 0.35)", stackUp, edge: false)
        }
        .padding(20)
        .background(DesktopFill(scheme: scheme))
        .environment(\.colorScheme, scheme)
    }

    private func row(_ title: String, _ frames: [Frame], edge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(frames) { frame in
                    VStack(spacing: 4) {
                        PreviewCard(item: item, actions: .inert, imageScale: frame.imageScale)
                            .scaleEffect(frame.scale, anchor: .bottom)
                            .offset(x: frame.x, y: frame.y)
                            .opacity(frame.opacity)
                            .frame(width: cell.width, height: cell.height)
                            .clipped()
                            .overlay(alignment: .trailing) {
                                // The screen edge the card comes from and goes to.
                                if edge { Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1) }
                            }
                            .background(Color.primary.opacity(0.04))
                        Text(verbatim: "\(Int(frame.time * 1_000)) ms")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A captured window with the rounded corners and shadow it has on screen.
private struct WindowShadow: View {
    let window: NSBitmapImageRep
    let scheme: ColorScheme

    var body: some View {
        Image(nsImage: ScreenshotHarness.image(window))
            .frame(width: window.size.width, height: window.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 20, y: 10)
            .padding(40)
    }
}

/// The popover as it looks open: under its menu bar icon, with the window's rounded corners
/// and shadow, over a plain desktop. Every part that carries information is the captured
/// panel or the real status icon; only the desktop, the menu bar strip and the clock are
/// scenery.
private struct HeroScene: View {
    let popover: NSBitmapImageRep
    let scheme: ColorScheme
    /// The 16:9 portfolio image: the same scene, wider, with the app's icon and name on the
    /// empty half of the desktop.
    let banner: Bool
    var icon: NSImage?

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                // What the app's MenuBarExtra label draws, highlighted the way the menu bar
                // marks the item whose window is open.
                StatusIconArt(state: .idle, phase: 0)
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.14)))
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .medium))
                // Fixed, so a re-render does not change the picture.
                Text(verbatim: "9:41")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))

            // Top-aligned: the popover hangs from the menu bar whatever its height, and the
            // banner's icon and name are centred on the desktop on their own.
            HStack(alignment: .top, spacing: 0) {
                if banner {
                    VStack(spacing: 20) {
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 176, height: 176)
                        }
                        Text(verbatim: Copy.appName)
                            .font(.system(size: 40, weight: .bold))
                    }
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
                Image(nsImage: ScreenshotHarness.image(popover))
                    .frame(width: popover.size.width, height: popover.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 12)
            }
            .padding(.top, 6)
            // A popover near the right edge is kept on screen rather than centred under its
            // icon, so it sits flush with a small margin. The banner's menu bar is wider, so
            // the popover moves in to stay under its icon.
            .padding(.trailing, banner ? 96 : 10)
            .padding(.bottom, banner ? 0 : 48)
            .frame(maxHeight: banner ? .infinity : nil, alignment: .top)
        }
        .frame(width: banner ? 960 : 440, height: banner ? 540 : nil)
        .foregroundStyle(dark ? Color.white : Color.black)
        .background(
            LinearGradient(colors: dark
                           ? [Color(red: 0.24, green: 0.09, blue: 0.10), Color(red: 0.27, green: 0.16, blue: 0.05)]
                           : [Color(red: 0.99, green: 0.84, blue: 0.80), Color(red: 0.99, green: 0.91, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, scheme)
    }
}

/// Every menu bar state and every phase of the copied flash, at 1x and 2x, on
/// light and dark menu bars and on two wallpapers. The glyphs are drawn as the menu bar
/// draws a template image: one colour, only the opacity varies.
private struct MenuBarStatesSheet: View {
    private struct Cell: Identifiable {
        let id: String
        let title: String
        let detail: String
        let state: StatusIconState
        let phase: Int
        var reduceMotion = false
    }

    private struct Strip: Identifiable {
        let id: String
        let background: AnyShapeStyle
        let glyph: Color
        let label: Color
    }

    private static let cells: [Cell] = {
        var cells = [
            Cell(id: "idle", title: "idle", detail: "", state: .idle, phase: 0),
            Cell(id: "paused", title: "paused", detail: "", state: .paused, phase: 0),
            Cell(id: "attention", title: "attention", detail: "", state: .attention, phase: 0),
            Cell(id: "copied-rm", title: "copied", detail: "Reduce Motion", state: .copied, phase: 1, reduceMotion: true),
        ]
        for phase in 1..<CopiedFlash.steps {
            let percent = Int((CopiedFlash.opacity(phase: phase) * 100).rounded())
            cells.append(Cell(id: "p\(phase)", title: "\(phase)", detail: "\(percent)%", state: .copied, phase: phase))
        }
        cells.append(Cell(id: "end", title: "\(CopiedFlash.steps)", detail: "end", state: .idle, phase: 0))
        return cells
    }()

    private static let strips: [Strip] = [
        Strip(id: "Light menu bar", background: AnyShapeStyle(Color(white: 0.95)), glyph: .black, label: .black),
        Strip(id: "Dark menu bar", background: AnyShapeStyle(Color(white: 0.12)), glyph: .white, label: .white),
        Strip(id: "Tinted wallpaper, light glyphs",
              background: AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.16, green: 0.25, blue: 0.62), Color(red: 0.52, green: 0.22, blue: 0.58),
                         Color(red: 0.86, green: 0.38, blue: 0.33)],
                startPoint: .leading, endPoint: .trailing)),
              glyph: .white, label: .white),
        Strip(id: "Tinted wallpaper, dark glyphs",
              background: AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.98, green: 0.80, blue: 0.70), Color(red: 0.80, green: 0.90, blue: 0.86),
                         Color(red: 0.78, green: 0.83, blue: 0.97)],
                startPoint: .leading, endPoint: .trailing)),
              glyph: .black, label: .black),
    ]

    private static let column: CGFloat = 52
    /// The sheet renders at 2x for legible labels; glyph images are framed at their pixel
    /// size divided by this, so each glyph pixel is one sheet pixel.
    static let scale: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "ClipShot menu bar states - 15 pt template symbol in a fixed 22 x 16 pt frame, the height the menu bar draws unscaled")
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: "Order: idle, paused, attention, copied with Reduce Motion; then the copied flash phases 1-14 (opacity of the check, the camera fades out as it fades in) and 15 = end, back to idle. Zoom rows are the 1x pixels enlarged 3x.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            header
            ForEach(Self.strips) { strip in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: strip.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(strip.label)
                    row(strip, scale: 1, zoom: 1, label: "1x")
                    row(strip, scale: 2, zoom: 1, label: "2x")
                    row(strip, scale: 1, zoom: 3, label: "1x zoom")
                }
                .padding(10)
                .background(strip.background)
            }
        }
        .padding(16)
        .frame(width: 80 + Self.column * CGFloat(Self.cells.count) + 40, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 70)
            ForEach(Self.cells) { cell in
                VStack(spacing: 1) {
                    Text(verbatim: cell.title).font(.system(size: 10, weight: .semibold))
                    Text(verbatim: cell.detail.isEmpty ? " " : cell.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(width: Self.column)
            }
        }
        .padding(.horizontal, 10)
    }

    private func row(_ strip: Strip, scale: CGFloat, zoom: CGFloat, label: String) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: label)
                .font(.system(size: 10))
                .foregroundStyle(strip.label)
                .frame(width: 70, alignment: .leading)
            ForEach(Self.cells) { cell in
                let glyph = Self.glyph(cell, color: strip.glyph, scale: scale)
                // One glyph pixel per sheet pixel at zoom 1.
                Image(decorative: glyph, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(glyph.width) * zoom / Self.scale, height: CGFloat(glyph.height) * zoom / Self.scale)
                    .frame(width: Self.column, height: max(28, CGFloat(glyph.height) * zoom / Self.scale))
            }
        }
    }

    private static func glyph(_ cell: Cell, color: Color, scale: CGFloat) -> CGImage {
        let renderer = ImageRenderer(content: StatusIconArt(state: cell.state, phase: cell.phase, reduceMotion: cell.reduceMotion)
            .foregroundStyle(color))
        renderer.scale = scale
        guard let image = renderer.cgImage else { ScreenshotHarness.fail("glyph render failed") }
        return image
    }
}

/// ClipShot's states next to VibeRes and Eject Guard, each drawn the way the menu bar draws
/// a MenuBarExtra label: rendered at 2x, then, when taller than
/// `StatusIconArt.menuBarHeight`, scaled down proportionally to it. VibeRes's label is a
/// plain `Image(systemName:)` at the menu bar's 13 pt; Eject Guard's is the symbol at
/// 15 pt in its own frame. Under each glyph: its ink box in 2x pixels.
private struct MenuBarOpticalSheet: View {
    private struct Item: Identifiable {
        let id: String
        let caption: String
        let image: CGImage
    }

    private struct Cluster: Identifiable {
        let id: String
        let items: [Item]
    }

    static let scale: CGFloat = 2

    private static func groups(_ color: Color) -> [Cluster] {
        let states: [(String, StatusIconState, Int)] = [
            ("idle", .idle, 0), ("paused", .paused, 0), ("attention", .attention, 0), ("copied", .copied, 6),
        ]
        return [
            Cluster(id: "ClipShot before (22 x 18 pt label)", items: states.map { name, state, phase in
                item(name, StatusIconArt(state: state, phase: phase).frame(width: 22, height: 18), color)
            }),
            Cluster(id: "ClipShot now (22 x 16 pt label)", items: states.map { name, state, phase in
                item(name, StatusIconArt(state: state, phase: phase), color)
            }),
            Cluster(id: "VibeRes", items: [
                item("rectangle.on.\nrectangle.angled", Image(systemName: "rectangle.on.rectangle.angled"), color),
            ]),
            Cluster(id: "Eject Guard (15 pt)", items: [
                item("externaldrive", Image(systemName: "externaldrive").font(.system(size: 15)), color),
                item("…fill.badge.\ntimemachine", Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 15)), color),
            ]),
        ]
    }

    private static func item(_ name: String, _ view: some View, _ color: Color) -> Item {
        let image = menuBarImage(view.foregroundStyle(color))
        let ink = inkSize(image)
        return Item(id: name, caption: "\(name)\n\(ink.width) x \(ink.height) px", image: image)
    }

    /// The label at 2x, fitted into the menu bar's height as AppKit fits a status item image.
    static func menuBarImage(_ view: some View) -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { ScreenshotHarness.fail("glyph render failed") }
        let limit = Int(StatusIconArt.menuBarHeight * scale)
        guard image.height > limit else { return image }
        let width = Int((CGFloat(image.width) * CGFloat(limit) / CGFloat(image.height)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: limit, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { ScreenshotHarness.fail("could not allocate a bitmap") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: limit))
        guard let scaled = context.makeImage() else { ScreenshotHarness.fail("could not scale a glyph") }
        return scaled
    }

    /// The bounding box of the pixels that are more than faintly drawn.
    static func inkSize(_ image: CGImage) -> (width: Int, height: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? (0, 0) : (maxX - minX + 1, maxY - minY + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Menu bar optical size - ClipShot beside VibeRes and Eject Guard")
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: "Each label is rendered at 2x and, when taller than 16 pt, scaled down to 16 pt as the menu bar does (the 22 x 18 pt label came out at 16/18 on a real menu bar). One glyph pixel per sheet pixel. Numbers: ink box in 2x pixels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            strip(background: Color(white: 0.95), glyph: .black)
            strip(background: Color(white: 0.12), glyph: .white)
            strip(background: Color(red: 0.36, green: 0.45, blue: 0.62), glyph: .white)
        }
        .padding(16)
        .frame(width: 900, alignment: .leading)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }

    private func strip(background: Color, glyph: Color) -> some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Self.groups(glyph)) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: group.id)
                        .font(.system(size: 10, weight: .semibold))
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(group.items) { item in
                            VStack(spacing: 4) {
                                // Its pixel size in points at the sheet's 2x: one glyph pixel per
                                // sheet pixel.
                                Image(decorative: item.image, scale: Self.scale)
                                    .frame(height: StatusIconArt.menuBarHeight + 6)
                                Text(verbatim: item.caption)
                                    .font(.system(size: 8))
                                    .multilineTextAlignment(.center)
                                    .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(glyph)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}
#endif
