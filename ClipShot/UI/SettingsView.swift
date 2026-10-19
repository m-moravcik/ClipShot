import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, capture, retention, about
}

/// Which Settings tab to show. The popover sets it before opening Settings ("Settings…"
/// opens General, as the siblings do; "Review" opens Retention).
@MainActor
@Observable
final class SettingsRouter {
    var tab: SettingsTab = .general
}

/// The panes are internal, not private, so the Debug screenshot harness can draw each one.
struct SettingsView: View {
    @Environment(SettingsRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            GeneralSettings()
                .tabItem { Label { Text(Copy.Tab.general) } icon: { Image(systemName: "gearshape") } }
                .tag(SettingsTab.general)
            CaptureSettingsPane()
                .tabItem { Label { Text(Copy.Tab.capture) } icon: { Image(systemName: "camera.viewfinder") } }
                .tag(SettingsTab.capture)
            RetentionSettings()
                .tabItem { Label { Text(Copy.Tab.retention) } icon: { Image(systemName: "trash") } }
                .tag(SettingsTab.retention)
            AboutSettings()
                .tabItem { Label { Text(Copy.Tab.about) } icon: { Image(systemName: "info.circle") } }
                .tag(SettingsTab.about)
        }
        .frame(width: Design.Layout.settingsSize.width, height: Design.Layout.settingsSize.height)
    }
}

/// An explanation under a control, as in Eject Guard. With an action, the button sits beside
/// the text, or under it in the text's column when it would take too much of the row.
private struct Note<Action: View>: View {
    let text: LocalizedStringResource
    var systemImage: String?
    var tint: Color?
    @ViewBuilder var action: Action

    var body: some View {
        if Action.self == EmptyView.self {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.s) {
                icon
                message
            }
        } else if systemImage != nil {
            TrailingActionLayout(hasIcon: true, iconSpacing: Design.Spacing.s, alignToFirstLine: true) {
                icon
                message
                action
            }
        } else {
            TrailingActionLayout(alignToFirstLine: true) {
                message
                action
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(Design.Typography.note)
                .foregroundStyle(tint ?? .secondary)
                .accessibilityHidden(true)
        }
    }

    private var message: some View {
        Text(text)
            .font(Design.Typography.note)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Note where Action == EmptyView {
    init(text: LocalizedStringResource, systemImage: String? = nil, tint: Color? = nil) {
        self.init(text: text, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    /// Replay was clicked while this pane was open: the button gives way to where the tour is.
    @State private var replayRequested: Bool

    /// A replayed tour exists for the render harness, which shows the note.
    init(replayRequested: Bool = false) {
        _replayRequested = State(initialValue: replayRequested)
    }

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )) { Text(Copy.General.launchAtLogin) }
            } header: {
                Text(Copy.General.startup)
            }

            Section {
                Toggle(isOn: $preferences.copyEnabled) {
                    Text(Copy.copyToClipboard)
                    Text(Copy.General.copyNote)
                }
                Toggle(isOn: $preferences.copySound) {
                    Text(Copy.General.copySound)
                    Text(Copy.General.copySoundNote)
                }
            } header: {
                Text(Copy.General.clipboard)
            }

            // Only once the tour has been seen: on a fresh install the user is in it. After a
            // click the tour waits in the popover, which Settings cannot open, so say so.
            if preferences.onboardingShown {
                Section {
                    Button {
                        model.replayOnboarding()
                        replayRequested = true
                    } label: { Text(Copy.General.replayTour) }
                }
            } else if replayRequested {
                Section { Note(text: Copy.General.replayNote, systemImage: "menubar.arrow.up.rectangle") }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.onboardingShown) { _, shown in
            if shown { replayRequested = false }
        }
    }
}

// MARK: - Capture

struct CaptureSettingsPane: View {
    /// The setting the user changed last, which carries the "applies from the next
    /// screenshot" note while screencaptureui still holds the old value.
    private enum Changed { case folder, thumbnail, destination, restore }

    @Environment(AppModel.self) private var model
    @State private var changed: Changed?
    @State private var restoreOutcome: Bool?

    var body: some View {
        Form {
            if !model.isWatching {
                Section { Note(text: Copy.Capture.notWatching) }
            } else {
                folderSection
                nativeSection
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.clearFolderError() }
    }

    @ViewBuilder
    private func appliesNote(_ setting: Changed) -> some View {
        if changed == setting, model.appliesFromNextScreenshot {
            Note(text: Copy.Capture.appliesNext, systemImage: "clock")
        }
    }

    private var folderSection: some View {
        Section {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.configuredFolder.map(AttentionPresentation.displayName) ?? "")
                        .lineLimit(1)
                    Text(verbatim: model.configuredFolder.map(model.displayPath) ?? "")
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Design.Spacing.m)
                Button { choose() } label: { Text(Copy.Capture.choose) }
            }
            if let error = model.folderError {
                Note(text: Copy.Capture.folderError(error), systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
            appliesNote(.folder)
        } header: {
            Text(Copy.Capture.saveFolder)
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Note(text: Copy.Capture.recordingsFollow)
                Spacer(minLength: Design.Spacing.m)
                Button { reset() } label: { Text(Copy.Capture.reset) }
                    .buttonStyle(.link)
                    .font(Design.Typography.note)
            }
        }
    }

    /// The floating thumbnail, the destination and the way back, in one section so the tab
    /// does not scroll.
    private var nativeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.showThumbnail },
                set: { on in
                    changed = .thumbnail
                    Task { await model.setShowThumbnail(on) }
                }
            )) {
                Text(Copy.Capture.showThumbnail)
                Text(Copy.Capture.thumbnailNote)
            }
            if model.pdfSavesNoFile {
                Note(text: Copy.Capture.pdfNote, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            appliesNote(.thumbnail)

            if model.destination == .file {
                Label {
                    Text(Copy.Capture.savedAsFiles)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Note(
                    text: AttentionPresentation.of(.destinationNotFile, destination: model.destination).message,
                    systemImage: "exclamationmark.triangle.fill", tint: .orange
                ) {
                    Button {
                        changed = .destination
                        Task { await model.fixDestination() }
                    } label: { Text(Copy.Action.saveToFile) }
                }
            }
            appliesNote(.destination)

            let restoreText = VStack(alignment: .leading, spacing: 2) {
                Text(Copy.Capture.restore)
                    .fixedSize(horizontal: false, vertical: true)
                Text(restoreOutcome.map { $0 ? Copy.Capture.restored : Copy.Capture.nothingToRestore }
                    ?? Copy.Capture.restoreNote)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TrailingActionLayout {
                restoreText.frame(maxWidth: .infinity, alignment: .leading)
                Button { restore() } label: { Text(Copy.Capture.restoreButton) }
            }
            appliesNote(.restore)
        }
    }

    /// "Applies from the next screenshot" only after a folder change that was accepted,
    /// never next to a folder error.
    private func choose() {
        guard let url = FolderPicker.choose(startingAt: model.configuredFolder) else { return }
        Task {
            do {
                try await model.setFolder(url)
                changed = .folder
            } catch {
                if changed == .folder { changed = nil }
            }
        }
    }

    private func reset() {
        Task {
            do {
                try await model.resetFolder()
                changed = .folder
            } catch {
                if changed == .folder { changed = nil }
            }
        }
    }

    private func restore() {
        changed = .restore
        Task { restoreOutcome = await model.restorePreviousSettings() }
    }
}

// MARK: - Retention

/// Which state the Retention tab is in. Pure, so it can be tested.
enum RetentionMode: Equatable {
    /// Onboarding has not reached the folder yet; nothing is read.
    case notWatching
    case off
    /// The toggle was switched on: the preview is shown and waits for "Turn on".
    case confirming
    case on
    /// On, but the folder changed since the preview was confirmed.
    case folderChanged
    /// On, but the folder can never be cleaned (no Trash, or a system or broad folder).
    case refused

    static func of(isWatching: Bool, policy: RetentionPolicy, refusal: Refusal?, pendingEnable: Bool) -> RetentionMode {
        guard isWatching else { return .notWatching }
        guard policy.enabled else { return pendingEnable ? .confirming : .off }
        switch refusal {
        case nil: return .on
        case .notConfirmed: return .folderChanged
        case .noTrash, .systemOrBroad: return .refused
        }
    }

    /// The period, preview and notes are shown while it is on or about to be.
    var showsDetails: Bool { self != .off && self != .notWatching }

    /// "Also clean up N older screenshots" only while retention is on and confirmed for
    /// this folder: adopting them is only meaningful when a run will move them.
    func offersAdoption(olderNotTracked: Int) -> Bool {
        self == .on && olderNotTracked > 0
    }
}

struct RetentionSettings: View {
    private enum Period: Hashable { case preset(Int), custom }

    private struct Offer: Equatable {
        let count: Int
        let bytes: Int64
        var size: String { bytes.formatted(.byteCount(style: .file)) }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingEnable = false
    @State private var customPeriod = false
    @State private var cleanUpOffer: Offer?
    @State private var adoptOffer: Offer?
    @State private var cleanUpOutcome: RetentionResult??

    private var mode: RetentionMode {
        .of(isWatching: model.isWatching, policy: model.preferences.retention,
            refusal: model.retentionRefusal, pendingEnable: pendingEnable)
    }

    private var scan: RetentionScan? {
        if case .success(let scan) = model.retentionPreview { scan } else { nil }
    }

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            if mode == .notWatching {
                Section { Note(text: Copy.Capture.notWatching) }
            } else {
                Section {
                    Toggle(isOn: Binding(
                        get: { preferences.retention.enabled || pendingEnable },
                        set: { setEnabled($0) }
                    )) { Text(Copy.Retention.enable) }
                    if mode.showsDetails {
                        periodPicker(preferences: preferences)
                    }
                } footer: {
                    if !mode.showsDetails { scopeNotes }
                }
                if mode.showsDetails {
                    previewSection
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPreview() }
        .confirmationDialog(
            cleanUpOffer.map { Text(Copy.Retention.cleanUpTitle($0.count, $0.size)) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { cleanUpOffer != nil }, set: { if !$0 { cleanUpOffer = nil } }),
            titleVisibility: .visible
        ) {
            Button { cleanUp() } label: { Text(Copy.Retention.moveToTrash) }
            Button(role: .cancel) {} label: { Text(Copy.Retention.cancel) }
        } message: {
            Text(Copy.Retention.cleanUpMessage)
        }
        .confirmationDialog(
            adoptOffer.map { Text(Copy.Retention.adoptTitle($0.count, $0.size)) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { adoptOffer != nil }, set: { if !$0 { adoptOffer = nil } }),
            titleVisibility: .visible
        ) {
            Button { Task { await model.adoptOlderScreenshots() } } label: { Text(Copy.Retention.adoptConfirm) }
            Button(role: .cancel) {} label: { Text(Copy.Retention.cancel) }
        } message: {
            Text(Copy.Retention.adoptMessage)
        }
    }

    private func setEnabled(_ on: Bool) {
        cleanUpOutcome = nil
        if on {
            pendingEnable = true
            model.refreshPreview()
        } else {
            pendingEnable = false
            model.preferences.retention.enabled = false
        }
    }

    @ViewBuilder
    private func periodPicker(preferences: Preferences) -> some View {
        let days = preferences.retention.days
        let selection = Binding<Period>(
            get: { customPeriod || !RetentionPolicy.presets.contains(days) ? .custom : .preset(days) },
            set: { choice in
                switch choice {
                case .custom:
                    customPeriod = true
                case .preset(let value):
                    customPeriod = false
                    preferences.retention.days = value
                }
            })
        Picker(selection: selection) {
            ForEach(RetentionPolicy.presets, id: \.self) { preset in
                Text(Copy.Retention.days(preset)).tag(Period.preset(preset))
            }
            Text(Copy.Retention.custom).tag(Period.custom)
        } label: {
            Text(Copy.Retention.period)
        }
        if selection.wrappedValue == .custom {
            Stepper(
                value: Binding(get: { preferences.retention.days }, set: { preferences.retention.days = $0 }),
                in: RetentionPolicy.dayRange
            ) {
                Text(Copy.Retention.days(days))
                    .monospacedDigit()
            }
        }
    }

    private var previewSection: some View {
        Section {
            previewLine
            if let scan {
                if scan.pending > 0 {
                    Note(text: Copy.Retention.pending(scan.pending))
                }
                if scan.skippedUnmarkedImages > 0 {
                    Note(text: Copy.Retention.skipped(scan.skippedUnmarkedImages))
                }
            }
            actions
        } footer: {
            scopeNotes
        }
    }

    private var scopeNotes: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.s) {
            Note(text: Copy.Retention.scope)
            Note(text: Copy.Retention.recordings)
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        switch model.retentionPreview {
        case .success(let scan):
            Text(scan.expired.isEmpty
                ? Copy.Retention.nothingWouldMove
                : Copy.Retention.wouldMove(scan.expired.count, scan.expiredBytes.formatted(.byteCount(style: .file))))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(scan.expired.count)))
                .animation(Design.Motion.number, value: scan.expired.count)
        case .failure(.systemOrBroad):
            Note(
                text: Copy.Retention.broad(folderName),
                systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .failure(.noTrash):
            Note(
                text: Copy.Attention.noTrash(folderName),
                systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .failure(.notConfirmed), nil:
            HStack(spacing: Design.Spacing.m) {
                ProgressView().controlSize(.small)
                Text(Copy.Retention.checking).foregroundStyle(.secondary)
            }
        }
    }

    private var folderName: String {
        model.screenshotFolder.map(AttentionPresentation.displayName) ?? ""
    }

    @ViewBuilder
    private var actions: some View {
        switch mode {
        case .confirming:
            HStack {
                Spacer()
                Button(role: .cancel) { pendingEnable = false } label: { Text(Copy.Retention.cancel) }
                Button { turnOn() } label: { Text(Copy.Retention.turnOn) }
                    .buttonStyle(.borderedProminent)
                    .disabled(scan == nil)
            }
        case .folderChanged:
            Note(
                text: Copy.Attention.retentionFolderChanged(folderName),
                systemImage: "exclamationmark.triangle.fill", tint: .orange)
            HStack {
                Spacer()
                Button { Task { await model.confirmRetentionFolder() } } label: { Text(Copy.Retention.resume) }
                    .buttonStyle(.borderedProminent)
                    .disabled(scan == nil)
            }
        case .on:
            if let scan, mode.offersAdoption(olderNotTracked: scan.olderNotTracked) {
                HStack {
                    Button {
                        adoptOffer = Offer(count: scan.olderNotTracked, bytes: scan.olderNotTrackedBytes)
                    } label: {
                        Text(Copy.Retention.adoptButton(
                            scan.olderNotTracked, scan.olderNotTrackedBytes.formatted(.byteCount(style: .file))))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A link, as "Reset to macOS default": it wraps where a push button
                    // would truncate a long translation.
                    .buttonStyle(.link)
                    Spacer()
                }
            }
            HStack {
                if let outcome = cleanUpOutcome {
                    if let result = outcome, result.moved > 0 {
                        Note(text: Copy.Retention.moved(result.moved, result.movedBytes.formatted(.byteCount(style: .file))))
                        Button { Task { await model.showTrash() } } label: { Text(Copy.Retention.showTrash) }
                            .buttonStyle(.link)
                    } else {
                        Note(text: Copy.Retention.nothingMoved)
                    }
                }
                Spacer()
                Button {
                    if let scan { cleanUpOffer = Offer(count: scan.expired.count, bytes: scan.expiredBytes) }
                } label: { Text(Copy.Retention.cleanUpNow) }
                    .disabled((scan?.expired.isEmpty ?? true))
            }
        case .off, .notWatching, .refused:
            EmptyView()
        }
    }

    private func turnOn() {
        Task {
            guard await model.turnOnRetention() else { return }
            pendingEnable = false
        }
    }

    private func cleanUp() {
        Task {
            let result = await model.cleanUpNow()
            cleanUpOutcome = .some(result)
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.updater) private var updater

    private static let repository = URL(string: "https://github.com/m-moravcik/ClipShot")!
    private static let portfolio = URL(string: "https://web.pexelo.com/portfolio")!

    private var version: LocalizedStringResource {
        let info = Bundle.main.infoDictionary
        return Copy.About.version(
            info?["CFBundleShortVersionString"] as? String ?? "?", info?["CFBundleVersion"] as? String ?? "?")
    }

    var body: some View {
        let totals = model.preferences.totals
        VStack(spacing: Design.Spacing.l) {
            // The app's own icon, at the size the standard About panel uses.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
                .padding(.top, Design.Spacing.l)

            VStack(spacing: Design.Spacing.s) {
                Text(verbatim: Copy.appName)
                    .font(.system(size: 16, weight: .semibold))
                Text(version)
                    .font(Design.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
            }

            Text(Copy.aboutDescription)
                .font(Design.Typography.note)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Design.Spacing.xl * 2)

            VStack(spacing: Design.Spacing.xs) {
                Text(Copy.About.copied(totals.copied))
                Text(Copy.About.freed(totals.freedBytes.formatted(.byteCount(style: .file))))
            }
            .font(Design.Typography.cardSubtitle)
            .accessibilityElement(children: .combine)

            if let updater, updater.isAvailable {
                VStack(spacing: Design.Spacing.s) {
                    Button { updater.checkForUpdates() } label: { Text(Copy.Update.check) }
                    Toggle(isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )) { Text(Copy.Update.checkAutomatically) }
                        .toggleStyle(.checkbox)
                        .font(Design.Typography.note)
                    Text(Copy.Update.checkAutomaticallyNote)
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Design.Spacing.xl * 2)
                }
            } else if let reason = updater?.unavailableReason {
                Text(verbatim: reason)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Design.Spacing.l) {
                Link(destination: Self.repository) { Text(Copy.About.sourceCode) }
                Link(destination: Self.portfolio) { Text(Copy.About.moreApps) }
            }
            .font(Design.Typography.note)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Design.Spacing.l)
    }
}
