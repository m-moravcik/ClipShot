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
            model.startCopying()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped once per copy while the result shows; the result's check bounces on it.
    @State private var bounce = 0
    /// The delay before the next bump; cancelled when the step goes away or a newer copy lands.
    @State private var bounceTask: Task<Void, Never>?

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
        // Driven by the copy itself, not by sampling the flash when the result appears: the
        // count goes up in the same step as the menu bar flash starts, and reopening the
        // popover changes no count, so the bounce fires once per copy and never replays.
        .onChange(of: model.preferences.totals.copied) { before, now in
            guard TrySuccessMotion.bounces(
                copiesBefore: before, copiesNow: now, showsResult: state.showsResult, reduceMotion: reduceMotion)
            else { return }
            bounceTask?.cancel()
            bounceTask = Task {
                do { try await Task.sleep(for: Design.Motion.successBounceDelay) } catch { return }
                bounce += 1
            }
        }
        .onDisappear {
            bounceTask?.cancel()
            bounceTask = nil
        }
    }

    @ViewBuilder
    private var tryResult: some View {
        ZStack {
            switch state {
            case .copied(let file):
                CopiedResult(
                    file: file, thumbnail: model.latest?.file == file ? model.latest?.thumbnail : nil,
                    bounce: bounce)
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

/// When Try it's success check bounces: once per copy, as its menu bar flash starts, while
/// the result shows, and never with Reduce Motion (the result's crossfade stays).
enum TrySuccessMotion {
    static func bounces(copiesBefore: Int, copiesNow: Int, showsResult: Bool, reduceMotion: Bool) -> Bool {
        copiesNow > copiesBefore && showsResult && !reduceMotion
    }
}

extension WelcomeTour.TryState {
    /// Try it shows a copied screenshot.
    var showsResult: Bool {
        if case .copied = self { true } else { false }
    }
}

/// The try's result: the thumbnail and "Copied", as the latest card shows it.
private struct CopiedResult: View {
    let file: CaptureFile
    let thumbnail: CGImage?
    /// Changes once per copy (see `FolderStep`); the check bounces on each change.
    let bounce: Int

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
                    .symbolEffect(
                        .bounce, options: .nonRepeating.speed(Design.Motion.successBounceSpeed), value: bounce)
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
                    .wrappingButtonStyle()
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
///
/// The period is a choice, not a fact (Michal: "it said retention 30 days, that confused
/// me"): one sentence, "Move screenshots older than [30 days] to the Trash", whose period is
/// a pop-up link with Settings' presets and Custom, next to the switch. The preview above
/// follows the chosen period.
private struct TidyStep: View {
    /// The period link's address: a click opens the period menu, nothing leaves the app.
    private static let periodURL = URL(string: "clipshot-period:choose")!

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customPeriod = false
    @State private var menuAnchor = MenuAnchor()

    private var scan: RetentionScan? {
        if case .success(let scan) = model.retentionPreview { scan } else { nil }
    }

    var body: some View {
        let retention = model.preferences.retention
        VStack(spacing: Design.Spacing.l) {
            StepHeader(symbol: "trash", title: Copy.Onboarding.tidyTitle, text: Copy.Onboarding.tidyBody)

            VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                previewLine
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                    .padding(.bottom, Design.Spacing.xs)

                periodRow(retention)
                if RetentionPeriod.of(days: retention.days, customRequested: customPeriod) == .custom {
                    Stepper(
                        value: Binding(get: { model.preferences.retention.days }, set: { model.preferences.retention.days = $0 }),
                        in: RetentionPolicy.dayRange
                    ) {
                        Text(Copy.Retention.days(retention.days))
                            .font(Design.Typography.body)
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                    .padding(.horizontal, Design.Spacing.l)
                    .transition(.opacity)
                }
                SwitchRow(
                    title: Copy.General.launchAtLogin,
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }),
                    font: Design.Typography.body)
            }
            .animation(Design.Motion.quick, value: customPeriod)
        }
        .onAppear { model.refreshPreview() }
    }

    /// The sentence with its period link, and the switch, laid out as `SwitchRow`.
    private func periodRow(_ retention: RetentionPolicy) -> some View {
        HStack(spacing: Design.Spacing.m) {
            Copy.Onboarding.tidyPeriod(periodLink(days: retention.days))
                .font(Design.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The period menu opens under the link, whether a click, the keyboard or
                // VoiceOver opened it: an anchor view sits on the link's own glyphs.
                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        let rect = Self.linkRect(layouts, in: proxy)
                        MenuAnchorView(anchor: menuAnchor)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
                    guard url == Self.periodURL else { return .systemAction }
                    showPeriodMenu()
                    return .handled
                })
                .accessibilityAction(named: Text(Copy.Retention.period)) { showPeriodMenu() }
            Toggle(isOn: Binding(
                get: { model.preferences.retention.enabled },
                set: { on in
                    if on {
                        Task { await model.turnOnRetention() }
                    } else {
                        model.preferences.retention.enabled = false
                    }
                })
            ) { Text(Copy.Retention.enable) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // On only for a folder the user has just seen a preview for.
                .disabled(!(retention.enabled || scan != nil))
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.s)
    }

    /// "30 days ▾" as a link, never broken across lines: the period and its arrow are one
    /// choice. Marked, so its place in the laid-out sentence can be found.
    private func periodLink(days: Int) -> Text {
        let period = String(localized: Copy.Retention.days(days)).replacingOccurrences(of: " ", with: "\u{00A0}")
        var link = AttributedString(period + "\u{00A0}\u{25BE}")
        link.link = Self.periodURL
        return Text(link).customAttribute(PeriodLinkAttribute())
    }

    /// The link's frame in the sentence's coordinates, from the text layout.
    private static func linkRect(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> CGRect {
        var rect = CGRect.null
        for anchored in layouts {
            let origin = proxy[anchored.origin]
            for line in anchored.layout {
                for run in line where run[PeriodLinkAttribute.self] != nil {
                    rect = rect.union(run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            }
        }
        return rect.isNull ? .zero : rect
    }

    /// Settings' choices, the current one checked, just under the link.
    private func showPeriodMenu() {
        let current = RetentionPeriod.of(days: model.preferences.retention.days, customRequested: customPeriod)
        let menu = NSMenu()
        for choice in RetentionPeriod.choices {
            let item = ClosureMenuItem(title: String(localized: choice.title)) { [model] in
                customPeriod = RetentionPeriod.choose(choice, preferences: model.preferences)
            }
            item.state = choice == current ? .on : .off
            if choice == .custom { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        if let view = menuAnchor.view, view.window != nil {
            let below = view.isFlipped ? view.bounds.maxY + 3 : view.bounds.minY - 3
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
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

/// Marks the period link inside the tour's sentence.
private struct PeriodLinkAttribute: TextAttribute {}

/// The view the period menu opens from.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: PassThroughView, context: Context) {
        anchor.view = view
    }

    /// Only a place to open the menu from: clicks go to the link above it.
    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
