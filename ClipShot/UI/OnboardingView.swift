import AppKit
import SwiftUI

/// The welcome tour's state: the step and what "Try it" has seen. A value the view keeps in
/// `@State`; it drives the model through its methods, so the tests run it on a real model.
///
/// Nothing here records the tour as shown except Done and Skip (`AppModel.finishOnboarding`).
struct WelcomeTour: Equatable {
    enum Step: Int, CaseIterable {
        /// What ClipShot does.
        case welcome
        /// Folder access, then "Try it".
        case folder
        /// The retention offer and launch at login.
        case tidy
    }

    /// What the prominent button does on the current step.
    enum Primary: Equatable {
        case next
        /// Step 2 before folder access: the first moment ClipShot touches the folder.
        case startCopying
        case done
    }

    static let stepCount = Step.allCases.count

    private(set) var step: Step
    /// Whether "Try it" has begun, and `lastCopied` at that moment. Only a different
    /// screenshot counts as the try, so a replayed tour does not show an old one.
    private(set) var trying = false
    private(set) var tryBaseline: CaptureFile?

    init(step: Step = .welcome) {
        self.step = step
    }

    /// 1-based, for "2 of 3".
    var number: Int { step.rawValue + 1 }
    var canGoBack: Bool { step != .welcome }

    @MainActor
    func primary(_ model: AppModel) -> Primary {
        switch step {
        case .welcome: .next
        case .folder: model.isWatching ? .next : .startCopying
        case .tidy: .done
        }
    }

    /// The prominent button.
    @MainActor
    mutating func advance(_ model: AppModel) {
        switch primary(model) {
        case .startCopying:
            model.startWatching()
            beginTry(model)
        case .next:
            step = Step(rawValue: step.rawValue + 1) ?? .tidy
            // A replayed tour already watches: "Try it" starts as soon as step 2 shows.
            if step == .folder, model.isWatching { beginTry(model) }
        case .done:
            model.finishOnboarding()
        }
    }

    mutating func back() {
        step = Step(rawValue: step.rawValue - 1) ?? .welcome
    }

    /// Skip is always there, on every step.
    @MainActor
    func skip(_ model: AppModel) {
        model.finishOnboarding()
    }

    @MainActor
    private mutating func beginTry(_ model: AppModel) {
        guard !trying else { return }
        trying = true
        tryBaseline = model.lastCopied
    }

    /// The screenshot copied since "Try it" began; nil while it waits.
    @MainActor
    func tried(_ model: AppModel) -> CaptureFile? {
        guard trying, let last = model.lastCopied, last != tryBaseline else { return nil }
        return last
    }
}

/// Three steps in the popover, as in VibeRes and Eject Guard: Skip and the step counter on
/// top, the step in the middle, dots and Back / Next at the bottom.
///
/// Steps change with `.id(step)` and a transition that slides in from the trailing edge,
/// or only crossfades under Reduce Motion, at `Design.Motion.quick`.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tour: WelcomeTour

    /// A tour other than a fresh one exists for the render harness, which shows each step.
    init(tour: WelcomeTour = WelcomeTour()) {
        _tour = State(initialValue: tour)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Group {
                switch tour.step {
                case .welcome: WelcomeStep()
                case .folder: FolderStep(tried: tour.tried(model))
                case .tidy: TidyStep()
                }
            }
            .id(tour.step)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            .padding(.horizontal, Design.Spacing.l + Design.Spacing.s)
            .padding(.top, Design.Spacing.m)
            .padding(.bottom, Design.Spacing.l)

            dots
                .padding(.bottom, Design.Spacing.m)

            bottomBar
        }
    }

    private var topBar: some View {
        HStack {
            Button { tour.skip(model) } label: { Text(Copy.Onboarding.skip) }
                .buttonStyle(.plain)
                .font(Design.Typography.note)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Copy.Onboarding.stepOf(tour.number, WelcomeTour.stepCount))
                .font(Design.Typography.note)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.top, Design.Spacing.l)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(WelcomeTour.Step.allCases, id: \.self) { step in
                Circle()
                    .fill(step == tour.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(Design.Motion.quick, value: tour.step)
        .accessibilityHidden(true)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                withAnimation(Design.Motion.quick) { tour.back() }
            } label: { Text(Copy.Onboarding.back) }
                .buttonStyle(.bordered)
                .disabled(!tour.canGoBack)

            Spacer(minLength: Design.Spacing.m)

            Button {
                withAnimation(Design.Motion.quick) { tour.advance(model) }
            } label: {
                switch tour.primary(model) {
                case .next: Text(Copy.Onboarding.next)
                case .startCopying: Text(Copy.Onboarding.startCopying)
                case .done: Text(Copy.Onboarding.done)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Spacing.l)
        .padding(.bottom, Design.Spacing.l)
    }
}

// MARK: - Steps

/// The icon, title and body every step starts with.
private struct StepHeader: View {
    /// Nil shows the app's own icon: the welcome step introduces the app.
    let symbol: String?
    let title: LocalizedStringResource
    let text: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                } else {
                    // The icon art carries its own margin, so it is drawn larger than the
                    // symbols to look the same size, as in the siblings.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                }
            }
            .frame(height: 56)
            .accessibilityHidden(true)
            .padding(.top, Design.Spacing.s)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        StepHeader(symbol: nil, title: Copy.Onboarding.welcomeTitle, text: Copy.Onboarding.welcomeBody)
    }
}

/// Explains folder access first; the bottom bar's "Start copying" asks for it. Then
/// "Try it" waits for the first copy and shows it.
private struct FolderStep: View {
    let tried: CaptureFile?

    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.isWatching {
                VStack(spacing: Design.Spacing.l) {
                    StepHeader(symbol: "camera.viewfinder", title: Copy.Onboarding.tryTitle, text: Copy.Onboarding.tryBody)
                    tryResult
                }
                .transition(.opacity)
            } else {
                StepHeader(symbol: "folder", title: Copy.Onboarding.folderTitle, text: Copy.Onboarding.folderBody)
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.quick, value: model.isWatching)
    }

    @ViewBuilder
    private var tryResult: some View {
        ZStack {
            if let tried {
                CopiedResult(file: tried, thumbnail: model.latest?.file == tried ? model.latest?.thumbnail : nil)
                    .transition(.opacity)
            } else if let attention = model.attentions.first {
                // Folder access denied, the clipboard destination and the like: the try can
                // not work until it is fixed, so say why here, with the row's own buttons.
                AttentionRow(attention: attention)
                    .transition(.opacity)
            } else {
                HStack(spacing: Design.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text(Copy.Onboarding.waiting)
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: Design.Layout.thumbnailSize.height)
                .padding(.vertical, Design.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .animation(Design.Motion.quick, value: tried)
        .animation(Design.Motion.quick, value: model.attentions.first)
    }
}

/// The try's result: the thumbnail and "Copied", as the latest card shows it.
private struct CopiedResult: View {
    let file: CaptureFile
    let thumbnail: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
        HStack(spacing: Design.Spacing.m) {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Design.Palette.chipFill)
                }
            }
            .frame(width: Design.Layout.thumbnailSize.width, height: Design.Layout.thumbnailSize.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Design.Palette.separator))
            .accessibilityHidden(true)

            Label {
                Text(Copy.Onboarding.copied)
                    .font(Design.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .accessibilityElement(children: .combine)
    }
}

/// The retention offer with the live preview above its switch, then launch at login.
/// Switching retention on confirms the folder the preview showed, as Settings does.
private struct TidyStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scan: RetentionScan? {
        if case .success(let scan) = model.retentionPreview { scan } else { nil }
    }

    var body: some View {
        let retention = model.preferences.retention
        VStack(spacing: Design.Spacing.l) {
            StepHeader(symbol: "trash", title: Copy.Onboarding.tidyTitle, text: Copy.Onboarding.tidyBody(retention.days))

            VStack(alignment: .leading, spacing: Design.Spacing.s) {
                previewLine
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))

                SwitchRow(
                    title: Copy.Retention.enable,
                    isOn: Binding(
                        get: { model.preferences.retention.enabled },
                        set: { on in
                            if on {
                                Task { await model.turnOnRetention() }
                            } else {
                                model.preferences.retention.enabled = false
                            }
                        }),
                    // On only for a folder the user has just seen a preview for.
                    isEnabled: retention.enabled || scan != nil)
                SwitchRow(
                    title: Copy.General.launchAtLogin,
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
        }
        .onAppear { model.refreshPreview() }
    }

    @ViewBuilder
    private var previewLine: some View {
        switch model.retentionPreview {
        case .success(let scan):
            Text(scan.expired.isEmpty
                ? Copy.Retention.nothingWouldMove
                : Copy.Retention.wouldMove(scan.expired.count, scan.expiredBytes.formatted(.byteCount(style: .file))))
                .font(Design.Typography.body)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(scan.expired.count)))
                .animation(Design.Motion.number, value: scan.expired.count)
        case .failure(.systemOrBroad):
            warning(Copy.Retention.broad(folderName))
        case .failure(.noTrash):
            warning(Copy.Attention.noTrash(folderName))
        case .failure(.notConfirmed), nil:
            HStack(spacing: Design.Spacing.m) {
                ProgressView().controlSize(.small)
                Text(Copy.Retention.checking)
                    .font(Design.Typography.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func warning(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Design.Typography.body)
    }

    private var folderName: String {
        model.screenshotFolder.map(AttentionPresentation.displayName) ?? ""
    }
}

/// A label that may wrap, with a small switch on the right, like the popover's copy row.
private struct SwitchRow: View {
    let title: LocalizedStringResource
    let isOn: Binding<Bool>
    var isEnabled = true

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            Text(title)
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            // The label stays for VoiceOver; the visible one is the text on the left.
            Toggle(isOn: isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.xs)
    }
}
