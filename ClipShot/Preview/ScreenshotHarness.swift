#if DEBUG
import AppKit
import ScreenCaptureKit
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
///
/// Off-screen there is nothing behind a window to blur, so the popover's material is drawn
/// as a solid fill and its bottom soft scroll edge is left out (`offscreenCapture`). With
/// `CLIPSHOT_SCREENSHOTS_LIVE=1` the popover pictures come from the window on screen through
/// ScreenCaptureKit instead, material and all. That needs Screen Recording for the Debug
/// build, which the harness never asks for: without it, it stops and says so.
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

    static let scratchKey = "CLIPSHOT_SCREENSHOTS_SCRATCH"

    /// Where the demo folders go, when the script names a place (build/screenshots-scratch).
    static var requestedScratch: URL? {
        guard let path = ProcessInfo.processInfo.environment[scratchKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static let liveKey = "CLIPSHOT_SCREENSHOTS_LIVE"

    /// Popover pictures from the window on screen (ScreenCaptureKit), not off-screen. Opt-in.
    static var liveCapture: Bool { ProcessInfo.processInfo.environment[liveKey] == "1" }

    /// Checks made while rendering (`checkMargin`); the run fails at the end when one
    /// did not hold, after every picture is written.
    private static var failedChecks: [String] = []

    static func run(into output: URL) -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Demo folders live in a scratch directory: the one `scripts/screenshots.sh` names under
        // build/, else one under the temporary directory. Resolved so every path the model
        // compares has one spelling. The harness never deletes it; the script trashes the
        // previous run's before it starts.
        let scratchRoot = requestedScratch ?? FileManager.default.temporaryDirectory
        let scratch = scratchRoot.resolvingSymlinksInPath()
            .appendingPathComponent("ClipShotScreenshots-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let shots = Shots(output: output)

            let icon = icon(pixels: 512)
            try shots.write(icon, "icon")
            try shots.write(render(MenuBarStatesSheet(), scale: MenuBarStatesSheet.scale), "menubar-states")
            try shots.write(render(MenuBarMomentsSheet(), scale: MenuBarMomentsSheet.scale), "menubar-moments")
            try MenuBarMomentsSheet.writeFrames(into: output.appendingPathComponent("peg-frames", isDirectory: true))
            try shots.write(render(MenuBarOpticalSheet(), scale: MenuBarOpticalSheet.scale), "menubar-optical-size")

            try renderMain(shots, scratch: scratch, icon: icon)
            try renderPaused(shots, scratch: scratch)
            try renderPausedByFocus(shots, scratch: scratch)
            try renderOne(shots, scratch: scratch)
            try renderAttentions(shots, scratch: scratch)
            try renderFull(shots, scratch: scratch)
            try renderTour(shots, scratch: scratch)
            try renderPreviews(shots, scratch: scratch)
        } catch {
            fail("\(error)")
        }
        if !failedChecks.isEmpty { fail(failedChecks.joined(separator: "\n")) }
        exit(0)
    }

    // MARK: Scenes

    /// The everyday popover: copying on, the screenshot just copied, a cleanup earlier today.
    /// Also the Settings panes and the hero and banner pictures.
    private static func renderMain(_ shots: Shots, scratch: URL, icon: NSBitmapImageRep) throws {
        let scene = try DemoScene(in: scratch)
        let now = Date()
        // Screenshots ClipShot saw being taken, just past 30 days: the real retention flow,
        // what Settings > Retention says would go to the Trash now.
        try awaitTask { try await scene.oldScreenshots(4, days: 31, tracked: true) }
        // Earlier screenshots it saw: the rows under the current one.
        try awaitTask { try await scene.recentScreenshots() }
        scene.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: ConfirmedFolder.of(scene.folder))
        scene.preferences.totals = Totals(copied: 148, freedBytes: 1_640_000_000, trashed: 412)
        guard scene.start() else { fail("the demo folder was not watched") }
        // Retention runs once at start. The demo Trash refuses every move, so the files stay
        // for the preview; then the summary is set to an earlier cleanup that worked, always
        // in the past and fixed to a time of day, so a re-render shows the same.
        DemoScene.wait { (scene.preferences.lastRetention?.failed ?? 0) > 0 }
        scene.preferences.lastRetention = RetentionResult(
            moved: 12, movedBytes: 38_400_000, failed: 0, at: DemoContent.lastCleanup(now: DemoContent.renderNow))
        try scene.copyDemoScreenshot()
        scene.model.refreshPreview()
        DemoScene.wait { scene.model.retentionPreview != nil }
        DemoScene.wait { scene.model.recent.count == RecentScreenshots.count }

        let updater = DemoUpdater()
        // Settings > General as a downloaded copy first shows it: clipshot not installed yet.
        let commandLine = try DemoCommandLine.make(.notInstalled, in: scratch)
        measure("popover", MenuContent().harnessEnvironment(scene.model, updater: updater), mustFit: true)
        for scheme in ColorScheme.allCases {
            let popover = capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
            try shots.write(popoverWindow(popover, scheme: scheme), "popover", scheme)
            // The second row's picture under the pointer: the pencil says it opens Markup.
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater)
                .environment(\.hoveredRecent, 1), scheme: scheme), scheme: scheme), "popover-recent-hover", scheme)
            // The pointer on the second row's Copy pill.
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater)
                .environment(\.hoveredRecentPill, HoveredPill(row: 1, pill: 0)), scheme: scheme), scheme: scheme),
                "popover-pill-hover", scheme)
            try shots.write(render(HeroScene(popover: popover, scheme: scheme, banner: false)), "hero", scheme)
            try shots.write(render(HeroScene(popover: popover, scheme: scheme, banner: true, icon: image(icon))), "banner", scheme)

            for tab in SettingsTab.allCases {
                let window = capture(SettingsWindow(tab: tab, scheme: scheme)
                    .harnessEnvironment(scene.model, updater: updater, commandLine: commandLine), scheme: scheme)
                try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-\(tab.name)", scheme)
            }
        }
        // Retention just after Clean up now: the outcome beside the button, with Show Trash;
        // then Show Trash finding no Trash it could open; then a run that moved nothing.
        let cleaned = RetentionResult(moved: 12, movedBytes: 38_400_000, failed: 0, at: now)
        let outcomes: [(String, RetentionResult??, Bool)] = [
            ("settings-retention-cleaned", .some(cleaned), false),
            ("settings-retention-trash-not-opened", .some(cleaned), true),
            ("settings-retention-nothing-moved", .some(nil), false),
        ]
        for scheme in ColorScheme.allCases {
            for (name, outcome, trashNotOpened) in outcomes {
                let window = capture(SettingsWindow(
                    tab: .retention, scheme: scheme, cleanUpOutcome: outcome, trashNotOpened: trashNotOpened)
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
                try shots.write(render(WindowShadow(window: window, scheme: scheme)), name, scheme)
            }
        }

        // Screenshots from before ClipShot ran: never cleaned up unless the user adds them,
        // so Settings offers them separately, with their own count.
        try awaitTask { try await scene.oldScreenshots(3, days: 41, tracked: false) }
        scene.model.refreshPreview()
        DemoScene.wait {
            if case .success(let scan) = scene.model.retentionPreview { scan.olderNotTracked > 0 } else { false }
        }
        for scheme in ColorScheme.allCases {
            let window = capture(SettingsWindow(tab: .retention, scheme: scheme)
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-retention-older", scheme)
        }

        // Just after Move to Trash on the second row: for 5 s the Undo strip in its place, the
        // other rows where they were, the older screenshot not yet on the last row. The demo
        // Trash refuses every move, so the file goes to a demo Trash folder by hand.
        let trash = scene.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        func moveToDemoTrash(_ moved: CaptureFile) throws {
            let inTrash = trash.appendingPathComponent(moved.url.lastPathComponent)
            try FileManager.default.moveItem(at: moved.url, to: inTrash)
            scene.model.showUndoForHarness(AppModel.TrashedScreenshot(file: moved, inTrash: inTrash))
            scene.model.screenshotLeft(moved)
            // The older screenshot is read in, and waits for Undo to be over.
            DemoScene.wait { scene.model.recent.count == RecentScreenshots.count && !scene.model.recent.contains(moved) }
            DemoScene.settle(0.6)
        }
        if scene.model.recent.count > 1 {
            try moveToDemoTrash(scene.model.recent[1])
            measure("popover-undo", MenuContent().harnessEnvironment(scene.model, updater: updater), mustFit: true)
            for scheme in ColorScheme.allCases {
                try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme), scheme: scheme), "popover-undo", scheme)
            }
            // A move that could not happen, said above the list.
            scene.model.showUndoForHarness(nil)
            scene.model.showNoteForHarness(.trash(.failed))
            DemoScene.settle(0.4)
            for scheme in ColorScheme.allCases {
                try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme), scheme: scheme), "popover-note", scheme)
            }
            scene.model.showNoteForHarness(nil)

            // Move to Trash on the floating preview of the screenshot just taken: its strip
            // on top, where its row was.
            try moveToDemoTrash(scene.model.recent[0])
            measure("popover-undo-top", MenuContent().harnessEnvironment(scene.model, updater: updater), mustFit: true)
            for scheme in ColorScheme.allCases {
                try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                    .harnessEnvironment(scene.model, updater: updater), scheme: scheme), scheme: scheme), "popover-undo-top", scheme)
            }
            scene.model.showUndoForHarness(nil)
        }

        // General's Command line section in each of its states.
        for state in DemoCommandLine.allCases {
            let setup = try DemoCommandLine.make(state, in: scratch)
            for scheme in ColorScheme.allCases {
                // Again for each picture: leaving the pane clears an outcome.
                try awaitTask { await DemoCommandLine.settle(setup, state) }
                let window = capture(SettingsWindow(tab: .general, scheme: scheme)
                    .harnessEnvironment(scene.model, updater: updater, commandLine: setup), scheme: scheme)
                checkMargin(window, "settings-general-cli-\(state.rawValue)", scheme: scheme)
                try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-general-cli-\(state.rawValue)", scheme)
            }
        }

        // General just after "Replay welcome tour": the tour waits in the popover.
        scene.model.replayOnboarding()
        for scheme in ColorScheme.allCases {
            let window = capture(SettingsWindow(tab: .general, scheme: scheme, replayed: true)
                .harnessEnvironment(scene.model, updater: updater, commandLine: commandLine), scheme: scheme)
            checkMargin(window, "settings-general-replayed", scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-general-replayed", scheme)
        }
        scene.stop()
    }

    /// The first screenshot ever: a list of one row.
    private static func renderOne(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        scene.preferences.totals = Totals(copied: 1, freedBytes: 0, trashed: 0)
        guard scene.start() else { fail("the demo folder was not watched") }
        try scene.copyDemoScreenshot()
        DemoScene.settle()
        measure("popover-one", MenuContent().harnessEnvironment(scene.model))
        for scheme in ColorScheme.allCases {
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), scheme: scheme), "popover-one", scheme)
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
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), scheme: scheme), "popover-paused", scheme)
        }
        scene.stop()
    }

    /// Copying paused by a Focus filter: the status line says a Focus paused it (Addendum C).
    /// The recent screenshots are there as on any day, none of them on the clipboard.
    private static func renderPausedByFocus(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        try awaitTask { try await scene.recentScreenshots() }
        scene.preferences.totals = Totals(copied: 148, freedBytes: 0, trashed: 0)
        guard scene.start() else { fail("the demo folder was not watched") }
        scene.model.focusChanged(pausing: true)
        DemoScene.wait { scene.model.recent.count == RecentScreenshots.count }
        DemoScene.settle()
        for scheme in ColorScheme.allCases {
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), scheme: scheme), "popover-paused-focus", scheme)
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
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model), scheme: scheme), scheme: scheme), "popover-attention", scheme)
            // The destination guard as Settings shows it, next to its fix.
            let window = capture(SettingsWindow(tab: .capture, scheme: scheme)
                .harnessEnvironment(scene.model), scheme: scheme)
            checkMargin(window, "settings-capture-attention", scheme: scheme)
            try shots.write(render(WindowShadow(window: window, scheme: scheme)), "settings-capture-attention", scheme)
        }

        // The tour's Try it on a replayed tour, blocked by the top attention row.
        var blocked = WelcomeTour()
        blocked.advance(scene.model)
        for scheme in ColorScheme.allCases {
            try shots.write(popoverWindow(capturePanel(tourPanel(blocked, scheme: scheme).harnessEnvironment(scene.model), scheme: scheme),
                                          scheme: scheme), "onboarding-2-try-attention", scheme)
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

    /// Every row the popover can show at once: an attention, the update card, the Undo strip,
    /// the four recent screenshots and the Markup tip. It is taller than the height cap in
    /// every language: the middle scrolls under a fixed header and footer.
    private static func renderFull(_ shots: Shots, scratch: URL) throws {
        let scene = try DemoScene(in: scratch)
        scene.preferences.markupTipShown = false
        scene.preferences.totals = Totals(copied: 3, freedBytes: 1_640_000_000, trashed: 412)
        scene.preferences.retention = RetentionPolicy(enabled: true, days: 30, confirmed: ConfirmedFolder.of(scene.folder))
        try awaitTask { try await scene.recentScreenshots() }
        guard scene.start() else { fail("the demo folder was not watched") }
        try scene.copyDemoScreenshot()
        DemoScene.wait { scene.model.recent.count == RecentScreenshots.count }
        scene.prefs["target"] = "clipboard"
        DemoScene.wait { !scene.model.attentions.isEmpty }
        // The Undo strip as just after a Move to Trash; drawn only, nothing is moved.
        if let shown = scene.model.recent.last {
            scene.model.showUndoForHarness(AppModel.TrashedScreenshot(
                file: shown, inTrash: scene.home.appendingPathComponent(".Trash/\(shown.url.lastPathComponent)")))
        }
        DemoScene.settle()
        measure("popover-full", MenuContent()
            .harnessEnvironment(scene.model, updateStatus: UpdateStatus(isUpdateReady: true)))
        for scheme in ColorScheme.allCases {
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updateStatus: UpdateStatus(isUpdateReady: true)), scheme: scheme),
                scheme: scheme), "popover-full", scheme)
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
            try shots.write(popoverWindow(capturePanel(tourPanel(tour, scheme: scheme).harnessEnvironment(trying.model), scheme: scheme),
                                          scheme: scheme), "onboarding-2-try-waiting", scheme)
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

        // Step 3 on a fresh install: nothing ClipShot saw being taken is old yet, but the
        // folder already holds older screenshots, offered as Settings offers them (U3).
        let tidyFresh = try DemoScene(in: scratch, onboardingShown: false)
        try awaitTask { try await tidyFresh.oldScreenshots(24, days: 60, tracked: false) }
        guard tidyFresh.start() else { fail("the demo folder was not watched") }
        tidyFresh.model.refreshPreview()
        DemoScene.wait {
            if case .success(let scan) = tidyFresh.model.retentionPreview { scan.olderNotTracked > 0 } else { false }
        }
        steps.append(("3-tidy-fresh", WelcomeTour(step: .tidy), tidyFresh))

        for scheme in ColorScheme.allCases {
            for (name, step, scene) in steps {
                try shots.write(popoverWindow(capturePanel(tourPanel(step, scheme: scheme).harnessEnvironment(scene.model), scheme: scheme),
                                              scheme: scheme), "onboarding-\(name)", scheme)
            }
        }
        for scene in [fresh, trying, tidy, tidyFresh] { scene.stop() }
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
            try shots.write(capture(PreviewDesktop(scheme: scheme) { PreviewStack(previews: scene.model.previews, files: .model(scene.model)) }
                .harnessEnvironment(scene.model), scheme: scheme), "preview", scheme)
            try shots.write(capture(PreviewDesktop(scheme: scheme, height: PreviewCardMetrics.maxSize.height + PreviewCardMetrics.margin * 2 + 20) {
                // Just taken, so it is the screenshot on the clipboard: Copied, and no Copy again.
                PreviewCard(item: single, actions: .inert, showsCopied: scene.model.previews.showsCopied(single), hovering: true)
                    .padding(PreviewCardMetrics.screenInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }.harnessEnvironment(scene.model), scheme: scheme), "preview-hover", scheme)
            // Moved to the Trash from the preview: Undo in its place (A6); and a move that
            // failed, said on the preview.
            var trashed = single
            trashed.trashed = true
            var failed = single
            failed.failure = .trash(.noTrash)
            try shots.write(capture(PreviewDesktop(
                scheme: scheme,
                height: PreviewCardMetrics.maxSize.height * 2 + PreviewCardMetrics.spacing + PreviewCardMetrics.margin * 2 + 20
            ) {
                VStack(alignment: .trailing, spacing: PreviewCardMetrics.spacing) {
                    PreviewCard(item: failed, actions: .inert)
                    PreviewCard(item: trashed, actions: .inert)
                }
                .padding(PreviewCardMetrics.screenInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }.harnessEnvironment(scene.model), scheme: scheme), "preview-undo", scheme)
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
            try shots.write(capture(PreviewDesktop(scheme: scheme) { PreviewStack(previews: scene.model.previews, files: .model(scene.model)) }
                .harnessEnvironment(scene.model), scheme: scheme), "preview-stack", scheme)
        }

        // Settings > Capture with the Preview picker, and the popover in Preview mode macOS.
        let updater = DemoUpdater()
        scene.prefs["show-thumbnail"] = true
        DemoScene.wait { scene.model.previewMode == .macOS }
        for scheme in ColorScheme.allCases {
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(scene.model, updater: updater), scheme: scheme), scheme: scheme), "popover-macos-mode", scheme)
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
            try shots.write(popoverWindow(capturePanel(PopoverPanel(scheme: scheme) { MenuContent() }
                .harnessEnvironment(upgraded.model, updater: updater), scheme: scheme), scheme: scheme), "popover-preview-offer", scheme)
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

    /// A popover or tour panel: off-screen by default, from the screen with `liveCapture`.
    private static func capturePanel(_ view: some View, scheme: ColorScheme) -> NSBitmapImageRep {
        liveCapture ? captureLive(view, scheme: scheme) : capture(view, scheme: scheme)
    }

    /// The panel in a window on screen, on the popover's material, captured by
    /// ScreenCaptureKit at 2x without the window shadow (`popoverWindow` draws that, as for
    /// an off-screen capture). A demo desktop is put behind it first, so the material blurs
    /// scenery and not whatever is on this screen. Never asks for Screen Recording.
    private static func captureLive(_ view: some View, scheme: ColorScheme) -> NSBitmapImageRep {
        guard CGPreflightScreenCaptureAccess() else {
            fail("live capture needs Screen Recording for this Debug build (System Settings > Privacy & "
                + "Security > Screen Recording). Unset \(liveKey) to render off-screen.")
        }
        guard let screen = NSScreen.main else { fail("live capture found no screen") }
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        hosting.appearance = appearance
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = appearance
        effect.maskImage = roundedMask(radius: 12)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let window = HarnessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = level
        window.appearance = appearance
        window.contentView = effect
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
        }
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6,
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true)

        let backdrop = NSWindow(contentRect: frame.insetBy(dx: -60, dy: -60), styleMask: [.borderless],
                                backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .statusBar
        backdrop.contentView = NSHostingView(rootView: DesktopFill(scheme: scheme))
        backdrop.orderFrontRegardless()
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            backdrop.orderOut(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let windowID = CGWindowID(window.windowNumber)
        let box = ImageBox()
        Task { @MainActor in
            do {
                box.outcome = .success(try await liveImage(windowID: windowID, size: size))
            } catch {
                box.outcome = .failure(error)
            }
        }
        DemoScene.wait(timeout: 10) { box.outcome != nil }
        guard let outcome = box.outcome else { fail("live capture timed out") }
        let image: CGImage
        do { image = try outcome.get() } catch { fail("live capture failed: \(error)") }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep
    }

    private static func liveImage(windowID: CGWindowID, size: CGSize) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width * 2)
        configuration.height = Int(size.height * 2)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
    }

    @MainActor
    private final class ImageBox {
        var outcome: Result<CGImage, any Error>?
    }

    /// A stretchable rounded-rectangle mask, the menu bar window's corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Checks

    /// Prints how tall the popover's content is and how tall the popover is (its height cap
    /// taken off, then on), and fails the run if the popover passes the cap.
    private static func measure(_ name: String, _ view: some View, mustFit: Bool = false) {
        func height(_ view: some View) -> CGFloat {
            let hosting = NSHostingView(rootView: view.frame(width: Design.Layout.popoverWidth))
            let window = HarnessWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: Design.Layout.popoverWidth, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            for _ in 0..<3 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                hosting.layoutSubtreeIfNeeded()
                window.setContentSize(hosting.fittingSize)
            }
            window.orderOut(nil)
            return hosting.fittingSize.height
        }
        let content = height(view.environment(\.popoverHeightCap, .infinity))
        let shown = height(view)
        let cap = Design.Layout.popoverMaxHeight
        print("measure: \(name) [\(DemoContent.language)] content \(Int(content.rounded())) pt, "
            + "popover \(Int(shown.rounded())) pt (cap \(Int(cap)))\(content > cap ? ", scrolls" : "")")
        if shown > cap + 0.5 {
            failedChecks.append("\(name) is \(shown) pt tall in \(DemoContent.language), past the \(cap) pt cap")
        }
        // The everyday popover, Undo strip and all, fits without scrolling in every language.
        if mustFit, content > cap + 0.5 {
            failedChecks.append("\(name) needs \(content) pt in \(DemoContent.language): it scrolls under the \(cap) pt cap")
        }
    }

    /// The Form's standard margin: what it leaves above its first section.
    static let standardMargin: CGFloat = 20

    /// A Settings pane must keep at least the Form's standard margin under its last section,
    /// in every language: less means the last row is about to be pushed out of the window,
    /// which then scrolls. Settings > Capture with the destination guard (Restore at the
    /// bottom) and Settings > General in every state of its Command line section are checked.
    /// Measured on the picture: rows of the pane's own fill, counted up from the window's
    /// bottom edge.
    private static func checkMargin(_ window: NSBitmapImageRep, _ name: String, scheme: ColorScheme) {
        let margin = bottomMargin(window)
        let language = DemoContent.language
        let appearance = scheme == .dark ? "dark" : "light"
        print("check: \(name) \(appearance) [\(language)] "
            + "bottom margin \(Int(margin.rounded(.down))) pt (minimum \(Int(standardMargin)))")
        if margin < standardMargin {
            failedChecks.append("\(name) leaves \(margin) pt under its last section in \(language) (\(appearance)), "
                + "less than the standard \(standardMargin) pt")
        }
    }

    /// Points of the pane's background colour between the content and the bottom edge.
    static func bottomMargin(_ rep: NSBitmapImageRep) -> CGFloat {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3, rep.bitsPerSample == 8 else { return 0 }
        let width = rep.pixelsWide, height = rep.pixelsHigh, row = rep.bytesPerRow, step = rep.samplesPerPixel
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = data + y * row + x * step
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        // The pane's own fill, just inside the bottom-left corner.
        let reference = pixel(4, height - 4)
        var y = height - 1
        scan: while y >= 0 {
            for x in 0..<width {
                let c = pixel(x, y)
                if abs(c.0 - reference.0) > 2 || abs(c.1 - reference.1) > 2 || abs(c.2 - reference.2) > 2 { break scan }
            }
            y -= 1
        }
        let pixels = height - 1 - y
        return CGFloat(pixels) * rep.size.height / CGFloat(height)
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

    /// A popover as it looks open: the panel with the window's rounded corners, hairline and
    /// shadow, on a transparent margin, the way the sibling apps' README pictures show theirs.
    private static func popoverWindow(_ panel: NSBitmapImageRep, scheme: ColorScheme) -> NSBitmapImageRep {
        render(PopoverWindow(panel: panel, scheme: scheme).padding(44))
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
    static func awaitTask(_ work: @escaping @MainActor @Sendable () async throws -> Void) throws {
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
        // What was printed so far first, so the message does not land inside a line.
        fflush(stdout)
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
        _ model: AppModel, updater: (any UpdaterProviding)? = nil, updateStatus: UpdateStatus = UpdateStatus(),
        commandLine: CommandLineSetup? = nil
    ) -> some View {
        environment(model)
            .environment(SettingsRouter())
            .environment(commandLine)
            .environment(updateStatus)
            .environment(\.updater, updater)
            .environment(\.offscreenCapture, !ScreenshotHarness.liveCapture)
            .environment(\.displayNow, DemoContent.renderNow)
    }
}

/// Settings > General > Command line on demo folders: a folder in the scratch directory
/// stands for "/", with the app, /usr/local/bin, Homebrew's bin and ~/.local/bin in it, shown
/// as the real paths. Nothing outside it is read or written, and the links are never made
/// through the real installer: Install and Fix answer from `DemoLinker`.
@MainActor
enum DemoCommandLine: String, CaseIterable {
    case notInstalled = "not-installed"
    case installing
    case cancelled
    case failed
    case copied
    case installed
    case homebrew
    case broken
    case otherCopy = "other-copy"
    case foreign
    case move

    static func make(_ state: DemoCommandLine, in scratch: URL) throws -> CommandLineSetup {
        let fm = FileManager.default
        let root = scratch.appendingPathComponent("cli-\(state.rawValue)", isDirectory: true)
        let home = root.appending(path: "Users/you")
        let app = state == .move
            ? root.appending(path: "private/var/folders/xy/AppTranslocation/1F2E/d/ClipShot.app")
            : root.appending(path: "Applications/ClipShot.app")
        let helper = app.appending(path: "Contents/Helpers/clipshot")
        let localBin = root.appending(path: "usr/local/bin"), brewBin = root.appending(path: "opt/homebrew/bin")
        let userBin = home.appending(path: ".local/bin")
        for folder in [helper.deletingLastPathComponent(), localBin, brewBin, userBin] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let tool = "clipshot"
        switch state {
        case .installed:
            try fm.createSymbolicLink(at: localBin.appending(path: tool), withDestinationURL: helper)
        case .homebrew:
            try fm.createSymbolicLink(at: brewBin.appending(path: tool), withDestinationURL: helper)
        case .broken:
            try fm.createSymbolicLink(
                atPath: localBin.appending(path: tool).path,
                withDestinationPath: root.appending(path: "Applications/Old/ClipShot.app/Contents/Helpers/clipshot").path)
        case .otherCopy:
            let other = home.appending(path: "Downloads/ClipShot.app/Contents/Helpers/clipshot")
            try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: other)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: other.path)
            try fm.createSymbolicLink(at: localBin.appending(path: tool), withDestinationURL: other)
        case .foreign:
            try Data("#!/bin/sh\n".utf8).write(to: userBin.appending(path: tool))
        case .notInstalled, .installing, .cancelled, .failed, .copied, .move:
            break
        }
        let locations = CommandLineLocations(
            helper: helper,
            candidates: [brewBin, localBin, userBin].map { $0.appending(path: tool) },
            installTarget: localBin.appending(path: tool),
            homebrewBundles: [],
            isHomebrewCopy: state == .homebrew,
            home: home,
            displayRoot: root)
        let result: CommandLineLinkResult = switch state {
        case .cancelled: .cancelled
        case .failed: .failed("The operation couldn’t be completed. (Disk full)")
        default: .linked
        }
        return CommandLineSetup(locations: locations, linker: DemoLinker(result: result))
    }

    /// Puts the section in the state's moment: after Install, during it, or after Copy
    /// Command (set, not clicked: the real button writes the clipboard).
    static func settle(_ setup: CommandLineSetup, _ state: DemoCommandLine) async {
        switch state {
        case .cancelled, .failed: await setup.install()
        case .installing: setup.activity = .working
        case .copied: setup.commandCopied = true
        default: break
        }
    }
}

/// Answers Install and Fix without touching anything.
private struct DemoLinker: CommandLineLinking {
    let result: CommandLineLinkResult

    func link(
        helper: URL, at link: URL, replacing: String?, asAdministrator: Bool, prompt: String
    ) async -> CommandLineLinkResult {
        result
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
    /// Only framed panels go through `capturePanel`, the one path that can capture live.
    private var live: Bool { framed && ScreenshotHarness.liveCapture }
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
        // A live popover or tour panel lets the window's material show through; everything
        // drawn off-screen, single rows included, gets the material's colour.
        .background(live ? Color.clear : scheme.popoverFill)
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
    /// Retention right after Clean up now, and when Show Trash found no Trash.
    var cleanUpOutcome: RetentionResult?? = nil
    var trashNotOpened = false

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
                .frame(width: tab.size.width, height: tab.size.height)
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
        case .retention: RetentionSettings(cleanUpOutcome: cleanUpOutcome, trashNotOpened: trashNotOpened)
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
            commitRow
            handRow
        }
        .padding(20)
        .background(DesktopFill(scheme: scheme))
        .environment(\.colorScheme, scheme)
    }

    /// A swipe held at these shares of the width: past the dismiss point the card tips and
    /// fades (end states of `Design.Motion.swipeCommit`).
    private var commitRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Swipe held, before release: past \(Int(PreviewCardMetrics.dismissFraction * 100)) % it tips and fades (a trackpad tick)")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach([0.0, 0.2, 0.38, 0.42, 0.6], id: \.self) { share in
                    VStack(spacing: 4) {
                        PreviewCard(item: item, actions: .inert, dragX: size.width * share)
                            .frame(width: cell.width, height: cell.height)
                            .clipped()
                            .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1) }
                            .background(Color.primary.opacity(0.04))
                        Text(verbatim: "\(Int(share * 100)) %")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// At rest, hovered (lifted, its shadow spread), and dragged out: the picture in hand,
    /// larger, raised and shadowed, while the card stays behind as a ghost.
    private var handRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "At rest, hover (lift), and a drag in hand (the drag image over the ghosted card)")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                PreviewCard(item: item, actions: .inert)
                    .frame(width: cell.width, height: cell.height)
                PreviewCard(item: item, actions: .inert, hovering: true)
                    .frame(width: cell.width, height: cell.height)
                ZStack {
                    PreviewCard(item: item, actions: .inert)
                        .opacity(Design.Motion.dragGhostOpacity)
                    if let image = item.image {
                        let lifted = DragLift.lifted(image, frame: NSRect(origin: .zero, size: size))
                        Image(nsImage: lifted.image)
                            .offset(x: 18, y: -DragLift.raise - 14)
                    }
                }
                .frame(width: cell.width + 40, height: cell.height)
            }
        }
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

/// The popover panel with the shape it has on screen: the menu bar window's rounded corners,
/// a hairline edge and its shadow. The hero, the banner and every popover picture share it.
private struct PopoverWindow: View {
    let panel: NSBitmapImageRep
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Image(nsImage: ScreenshotHarness.image(panel))
            .frame(width: panel.size.width, height: panel.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 12)
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
                PopoverWindow(panel: popover, scheme: scheme)
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

/// Every menu bar state and every frame of the copy animation, at 1x and 2x, on light and
/// dark menu bars and on two wallpapers. The glyphs are drawn as the menu bar draws a
/// template image: one colour, only the opacity varies.
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
        for phase in 1..<PegFlash.steps {
            let time = String(format: "%.2f s", PegFlash.time(phase: phase))
            cells.append(Cell(id: "p\(phase)", title: "\(phase)", detail: time, state: .copied, phase: phase))
        }
        cells.append(Cell(id: "end", title: "\(PegFlash.steps)", detail: "end", state: .idle, phase: 0))
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

    /// Measured from the glyph as drawn, so the numbers stay true when the frame or the
    /// symbol size changes.
    private static let title: String = {
        let frame = StatusIconArt.frame
        let idle = glyph(Cell(id: "idle", title: "", detail: "", state: .idle, phase: 0), color: .black, scale: 1)
        let ink = GlyphInk.size(idle)
        return "ClipShot menu bar states - Peg, a template image (idle: \(ink.width) x \(ink.height) px at 1x) "
            + "in a fixed \(Int(frame.width)) x \(Int(frame.height)) pt frame, the height the menu bar draws unscaled"
    }()

    private static let column: CGFloat = 72
    /// The sheet renders at 2x for legible labels; glyph images are framed at their pixel
    /// size divided by this, so each glyph pixel is one sheet pixel.
    static let scale: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: Self.title)
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: "Order: idle, paused, attention, copied (held as is with Reduce Motion); then every frame of the \(String(format: "%.1f", PegFlash.duration)) s copy animation at \(Int(PegFlash.frameRate)) fps (frame, seconds in) and the end, back to idle. Zoom rows are the 1x pixels enlarged 3x.")
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

    static let scale = GlyphInk.scale

    private static func groups(_ color: Color) -> [Cluster] {
        let states: [(String, StatusIconState)] = [
            ("idle", .idle), ("paused", .paused), ("attention", .attention), ("copied", .copied),
        ]
        return [
            Cluster(id: "ClipShot before (SF Symbol, 15 pt)", items: [
                item("camera.\nviewfinder", Image(systemName: "camera.viewfinder").font(.system(size: 15))
                    .frame(width: 22, height: 16), color),
            ]),
            Cluster(id: "ClipShot now: Peg (22 x 16 pt label)", items: states.map { name, state in
                item(name, StatusIconArt(state: state, phase: 0), color)
            }),
            Cluster(id: "VibeRes", items: [
                item("rectangle.on.\nrectangle.angled", Image(systemName: "rectangle.on.rectangle.angled"), color),
            ]),
            Cluster(id: "Eject Guard (15 pt)", items: [
                item("externaldrive", GlyphInk.ejectGuardLabel(), color),
                item("…fill.badge.\ntimemachine", Image(systemName: "externaldrive.fill.badge.timemachine")
                    .font(.system(size: 15)), color),
            ]),
        ]
    }

    private static func item(_ name: String, _ view: some View, _ color: Color) -> Item {
        guard let image = GlyphInk.menuBarImage(view.foregroundStyle(color)) else {
            ScreenshotHarness.fail("glyph render failed")
        }
        let ink = GlyphInk.size(image)
        return Item(id: name, caption: "\(name)\n\(ink.width) x \(ink.height) px", image: image)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Menu bar optical size - ClipShot beside VibeRes and Eject Guard")
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: "Each label is rendered at 2x and, when taller than 16 pt, scaled down to 16 pt as the menu bar does (a 22 x 18 pt label came out at 16/18 on a real menu bar). One glyph pixel per sheet pixel. Numbers: ink box in 2x pixels.")
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
