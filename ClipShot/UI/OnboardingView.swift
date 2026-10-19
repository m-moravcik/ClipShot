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

    /// Which way the last step change went, so the new step slides in from that side.
    enum Direction: Equatable {
        case forward, backward
    }

    /// What step 2's Try it shows below its text.
    enum TryState: Equatable {
        /// Folder access asked for, nothing copied since.
        case waiting
        /// The screenshot copied since Try it began.
        case copied(CaptureFile)
        /// Something stops copying (access denied, clipboard destination…): its row says what.
        case attention(Attention)
        /// The Copy to clipboard switch is off, so a screenshot would never arrive.
        case paused
    }

    static let stepCount = Step.allCases.count

    private(set) var step: Step
    private(set) var direction = Direction.forward
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
            direction = .forward
            step = Step(rawValue: step.rawValue + 1) ?? .tidy
            // A replayed tour already watches: "Try it" starts as soon as step 2 shows.
            if step == .folder, model.isWatching { beginTry(model) }
        case .done:
            model.finishOnboarding()
        }
    }

    mutating func back() {
        guard canGoBack else { return }
        direction = .backward
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

    /// A copy wins; then what blocks copying (an attention, then the paused switch); else
    /// it waits.
    @MainActor
    func tryState(_ model: AppModel) -> TryState {
        if let file = tried(model) { return .copied(file) }
        if let attention = model.attentions.first { return .attention(attention) }
        if !model.preferences.copyEnabled { return .paused }
        return .waiting
    }
}

/// Three steps in the popover, as in VibeRes and Eject Guard: Skip and the step counter on
/// top, the step in the middle, dots and Back / Next at the bottom.
///
/// Steps change with `.id(step)` inside a `ZStack`, so the outgoing and the incoming step
/// overlap instead of stacking for the length of the transition. The new step slides in from
/// the side the user moved towards (Next: trailing, Back: leading) while the old one fades
/// out in place; Reduce Motion keeps only the crossfade. All at `Design.Motion.quick`.
///
/// The removal is a fade rather than a slide on purpose: SwiftUI removes a view with the
/// transition it had when it was last drawn, which after a change of direction is the old
/// direction's, so a sliding removal would go the wrong way on the first Back after Next.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tour: WelcomeTour

    /// A tour other than a fresh one exists for the render harness, which shows each step.
    init(tour: WelcomeTour = WelcomeTour()) {
        _tour = State(initialValue: tour)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edge: Edge = tour.direction == .forward ? .trailing : .leading
        return .asymmetric(insertion: .opacity.combined(with: .move(edge: edge)), removal: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ZStack(alignment: .top) {
                Group {
                    switch tour.step {
                    case .welcome: WelcomeStep()
                    case .folder: FolderStep(state: tour.tryState(model))
                    case .tidy: TidyStep()
                    }
                }
                .id(tour.step)
                .transition(stepTransition)
            }
            .padding(.horizontal, Design.Spacing.l + Design.Spacing.s)
            .padding(.top, Design.Spacing.m)
            .padding(.bottom, Design.Spacing.l)
            .clipped()

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

    /// Back and the primary button side by side, or stacked at full width (primary first)
    /// when a translation makes them wider than the popover.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                backButton(stretched: false)
                Spacer(minLength: Design.Spacing.m)
                primaryButton(stretched: false)
            }
            VStack(spacing: Design.Spacing.s) {
                primaryButton(stretched: true)
                backButton(stretched: true)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Spacing.l)
        .padding(.bottom, Design.Spacing.l)
    }

    private func backButton(stretched: Bool) -> some View {
        Button {
            withAnimation(Design.Motion.quick) { tour.back() }
        } label: {
            Text(Copy.Onboarding.back)
                .frame(maxWidth: stretched ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .disabled(!tour.canGoBack)
        .fixedSize(horizontal: !stretched, vertical: true)
    }

    private func primaryButton(stretched: Bool) -> some View {
        Button {
            withAnimation(Design.Motion.quick) { tour.advance(model) }
        } label: {
            Group {
                switch tour.primary(model) {
                case .next: Text(Copy.Onboarding.next)
                case .startCopying: Text(Copy.Onboarding.startCopying)
                case .done: Text(Copy.Onboarding.done)
                }
            }
            .frame(maxWidth: stretched ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .fixedSize(horizontal: !stretched, vertical: true)
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
    let state: WelcomeTour.TryState

    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.isWatching {
                VStack(spacing: Design.Spacing.l) {
                    StepHeader(
                        symbol: "camera.viewfinder", title: Copy.Onboarding.tryTitle,
                        text: Copy.Onboarding.tryBody(model.previewMode))
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
            switch state {
            case .copied(let file):
                CopiedResult(file: file, thumbnail: model.latest?.file == file ? model.latest?.thumbnail : nil)
                    .transition(.opacity)
            case .attention(let attention):
                // The try can not work until this is fixed, so say why here, with the row's
                // own buttons.
                AttentionRow(attention: attention)
                    .transition(.opacity)
            case .paused:
                PausedResult()
                    .transition(.opacity)
            case .waiting:
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
        .animation(Design.Motion.quick, value: state)
    }
}

/// The try's result: the thumbnail and "Copied", as the latest card shows it.
private struct CopiedResult: View {
    let file: CaptureFile
    let thumbnail: CGImage?

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            MarkupThumbnail(image: thumbnail, file: file)
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
        .accessibilityElement(children: .contain)
    }
}

/// Copying is switched off: say so, with the way back on, instead of waiting forever.
private struct PausedResult: View {
    @Environment(AppModel.self) private var model

    private var turnOn: some View {
        Button { model.preferences.copyEnabled = true } label: { Text(Copy.Onboarding.turnOnCopying) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Copy.Onboarding.paused)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Design.Typography.body)
            // A native button, or one whose title wraps when a translation is too long.
            ViewThatFits(in: .horizontal) {
                turnOn
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                turnOn
                    .buttonStyle(WrappingButtonStyle())
                    .focusEffectDisabled()
            }
            .padding(.leading, Design.Layout.iconColumn + Design.Spacing.s)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
        .accessibilityElement(children: .contain)
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

            VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                previewLine
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                    .padding(.bottom, Design.Spacing.xs)

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
                    isEnabled: retention.enabled || scan != nil,
                    font: Design.Typography.body)
                SwitchRow(
                    title: Copy.General.launchAtLogin,
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
                    font: Design.Typography.body)
            }
        }
        .onAppear { model.refreshPreview() }
    }

    /// Before the switch: what would go now. After it: what goes at the next cleanup.
    private func previewText(_ scan: RetentionScan, on: Bool) -> LocalizedStringResource {
        let size = scan.expiredBytes.formatted(.byteCount(style: .file))
        switch (on, scan.expired.isEmpty) {
        case (false, true): return Copy.Retention.nothingWouldMove
        case (false, false): return Copy.Retention.wouldMove(scan.expired.count, size)
        case (true, true): return Copy.Retention.nothingDue
        case (true, false): return Copy.Retention.willMove(scan.expired.count, size)
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        switch model.retentionPreview {
        case .success(let scan):
            Text(previewText(scan, on: model.preferences.retention.enabled))
                .font(Design.Typography.body)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(scan.expired.count)))
                .animation(Design.Motion.number, value: scan.expired.count)
                .animation(Design.Motion.quick, value: model.preferences.retention.enabled)
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
