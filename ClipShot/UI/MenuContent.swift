import AppKit
import SwiftUI

/// The popover, in the spec's order: header, attention rows, latest screenshot, the copy
/// toggle, the retention summary, the update row, then the native-menu footer.
///
/// Motion is opacity-led and quiet, as in the siblings: rows fade (never slide, the window
/// would clip them), hover fills switch without animation, and nothing animates in when the
/// popover opens, because everything it shows is already decoded and in the model.
struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateStatus.self) private var updateStatus
    @Environment(\.updater) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var attentionsExpanded = false

    var body: some View {
        // The welcome tour until Done or Skip; Settings > General can bring it back.
        ZStack {
            if model.preferences.onboardingShown {
                main
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.quick, value: model.preferences.onboardingShown)
        .frame(width: Design.Layout.popoverWidth)
        .frame(maxHeight: Design.Layout.popoverMaxHeight)
        // Intrinsic height, not the tallest state the popover has shown.
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
    }

    private var main: some View {
        // One scroll view whatever the height, so the rows keep their identity (and state, such
        // as Copy again's checkmark) when a long translation takes the popover past its cap. It
        // scrolls only then. The header is its top bar: rows scrolling under it soften into the
        // edge, as macOS 26 draws content under bars. At the bottom they run under the footer's
        // separator, the edge a native menu or list has. (A bar there too renders the scroll view
        // black in the offscreen harness, which the README pictures come from.)
        VStack(spacing: 0) {
            ScrollView { middle }
                .scrollBounceBehavior(.basedOnSize)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    PopoverHeader()
                        .padding(.bottom, Design.Spacing.m)
                }
            FooterSeparator()
            FooterBar()
        }
        .animation(reduceMotion ? nil : Design.Motion.layout, value: model.attentions)
        .animation(reduceMotion ? nil : Design.Motion.layout, value: attentionsExpanded)
        .animation(reduceMotion ? nil : Design.Motion.layout, value: updateStatus.isUpdateReady)
        .animation(reduceMotion ? nil : Design.Motion.layout, value: model.showMarkupTip)
        .animation(reduceMotion ? nil : Design.Motion.layout, value: model.showsPreviewOffer)
        .onChange(of: model.attentions.count) { _, count in
            if count <= 1 { attentionsExpanded = false }
        }
        // A screenshot deleted in Finder since the last look leaves the card and the strip.
        .onAppear { model.refreshRecent() }
    }

    private var middle: some View {
        VStack(spacing: Design.Spacing.m) {
            attentionRows
            if model.showsPreviewOffer {
                PreviewOfferRow()
                    .transition(.opacity)
            }
            LatestCaptureSection()
            if model.showMarkupTip {
                MarkupTip()
                    .transition(.opacity)
            }
            CopyToggleRow()
            RetentionSummaryRow()
            if updateStatus.isUpdateReady {
                UpdateReadyCard { updater?.installUpdate() }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Design.Spacing.m)
        .padding(.bottom, FooterSeparator.inset)
    }

    @ViewBuilder
    private var attentionRows: some View {
        let visible = AttentionPresentation.visible(model.attentions, expanded: attentionsExpanded)
        if !visible.rows.isEmpty {
            VStack(alignment: .leading, spacing: Design.Spacing.s) {
                ForEach(visible.rows) { attention in
                    AttentionRow(attention: attention)
                        .transition(.opacity)
                }
                if visible.hidden > 0 || attentionsExpanded && model.attentions.count > 1 {
                    Button {
                        attentionsExpanded.toggle()
                    } label: {
                        Text(visible.hidden > 0 ? Copy.Attention.more(visible.hidden) : Copy.Attention.showLess)
                            .font(Design.Typography.note)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Design.Spacing.l)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Header

/// The popover's first row, as Eject Guard's status row: the state with a symbol in its tint,
/// and one line under it. No app name: the siblings never show theirs. Pure, so it can be
/// tested.
struct HeaderStatus: Equatable {
    enum Detail: Equatable {
        /// Preview mode ClipShot or None.
        case pasteAtOnce
        /// Preview mode macOS while the one-time offer row says what it costs.
        case pasteAfterThumbnail
        /// Preview mode macOS: copying waits, with Copy at once next to it (A1).
        case thumbnailWait
        case paused
        case issues(Int)
    }

    let state: StatusIconState
    let detail: Detail

    static func of(state: StatusIconState, previewMode: PreviewMode, showsThumbnailWait: Bool, attentions: Int) -> HeaderStatus {
        switch state {
        case .attention: HeaderStatus(state: .attention, detail: .issues(attentions))
        case .paused: HeaderStatus(state: .paused, detail: .paused)
        case .idle, .copied:
            HeaderStatus(
                state: .idle,
                detail: showsThumbnailWait ? .thumbnailWait : previewMode.copiesInstantly ? .pasteAtOnce : .pasteAfterThumbnail)
        }
    }

    var title: LocalizedStringResource {
        switch state {
        case .attention: Copy.Header.attention
        case .paused: Copy.Header.paused
        case .idle, .copied: Copy.Header.on
        }
    }

    var symbol: String {
        switch state {
        case .attention: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .idle, .copied: "checkmark.circle.fill"
        }
    }

    /// Green while copying, the attention rows' orange when something needs fixing.
    var tint: Color {
        switch state {
        case .attention: .orange
        case .paused: .secondary
        case .idle, .copied: .green
        }
    }

    var detailText: LocalizedStringResource {
        switch detail {
        case .pasteAtOnce: Copy.Header.firstCopyHintInstant
        case .pasteAfterThumbnail: Copy.Header.firstCopyHint
        case .thumbnailWait: Copy.ThumbnailWait.hint
        case .paused: Copy.Header.pausedDetail
        case .issues(let count): Copy.Header.attentionDetail(count)
        }
    }
}

private struct PopoverHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let status = HeaderStatus.of(
            state: model.headerState, previewMode: model.previewMode,
            showsThumbnailWait: model.showsThumbnailWait, attentions: model.attentions.count)
        HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
            Image(systemName: status.symbol)
                .font(.system(size: 13))
                .foregroundStyle(status.tint)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(width: Design.Layout.iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(Design.Typography.cardTitle)
                    .contentTransition(.opacity)
                detail(status)
                    .font(Design.Typography.note)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Design.Motion.quick, value: status)
        .accessibilityElement(children: .contain)
        .padding(.horizontal, Design.Spacing.l + Design.Spacing.m)
        .padding(.top, Design.Spacing.l)
    }

    @ViewBuilder
    private func detail(_ status: HeaderStatus) -> some View {
        let text = Text(status.detailText).foregroundStyle(.secondary)
        if status.detail == .thumbnailWait {
            // On one line when it fits, else the link under the sentence.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.s) {
                    text.fixedSize()
                    useClipShotLink
                }
                VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                    text.fixedSize(horizontal: false, vertical: true)
                    useClipShotLink
                }
            }
        } else {
            text
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }

    private var useClipShotLink: some View {
        Button { Task { await model.setPreviewMode(.clipShot) } } label: {
            Text(Copy.ThumbnailWait.useClipShot)
        }
        .buttonStyle(.link)
        .fixedSize()
    }
}

// MARK: - Rows

private struct MarkupTip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.m) {
            Image(systemName: "pencil.tip.crop.circle")
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(Copy.Latest.markupTip(model.previewMode))
                .font(Design.Typography.note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.dismissMarkupTip() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(Copy.Action.dismiss))
            .help(Text(Copy.Action.dismiss))
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.rowSelectedFill))
    }
}

/// After an update, while the macOS thumbnail is on: a one-time offer to copy at once, with
/// what the thumbnail costs. ClipShot never turns the thumbnail off on its own; Copy at once
/// does it through the backup, and the close button keeps things as they are for good.
private struct PreviewOfferRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
                Image(systemName: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(width: Design.Layout.iconColumn)
                    .accessibilityHidden(true)
                Text(Copy.ThumbnailWait.offer)
                    .font(Design.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.dismissPreviewOffer() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Copy.Action.dismiss))
                .help(Text(Copy.Action.dismiss))
            }
            Button { Task { await model.acceptPreviewOffer() } } label: {
                Text(Copy.ThumbnailWait.useClipShot)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.leading, Design.Layout.iconColumn + Design.Spacing.m)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.attentionFill))
        .accessibilityElement(children: .contain)
    }
}

private struct CopyToggleRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        SwitchRow(title: Copy.copyToClipboard, isOn: $preferences.copyEnabled, icon: "doc.on.clipboard")
    }
}

/// The quiet retention row (A7): its state, "Retention is off" or the tour's sentence shape
/// "Older than 30 days go to the Trash", then what it did. Opens Settings >
/// Retention. Pure, so it can be tested.
enum RetentionSummary: Equatable {
    case off
    /// On, but this folder can never be cleaned: no Trash, or a system or broad folder.
    case offForFolder
    /// On, but waiting for the user to confirm a new folder.
    case paused
    case on(days: Int)

    static func of(policy: RetentionPolicy, refusal: Refusal?) -> RetentionSummary {
        guard policy.enabled else { return .off }
        switch refusal {
        case nil: return .on(days: policy.days)
        case .notConfirmed: return .paused
        case .noTrash, .systemOrBroad: return .offForFolder
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .off: Copy.Summary.off
        case .offForFolder: Copy.Summary.offForFolder
        case .paused: Copy.Summary.paused
        case .on(let days): Copy.Summary.olderGo(days)
        }
    }

    /// "Last cleanup today at 14:00, 3 moved", or the date when it was not today. Only runs
    /// that moved or failed something are recorded, so nil means none has been needed yet.
    static func lastCleanup(_ result: RetentionResult?, now: Date, calendar: Calendar = .current) -> LocalizedStringResource {
        guard let result else { return Copy.Summary.noCleanupYet }
        if calendar.isDate(result.at, inSameDayAs: now) {
            return Copy.Summary.lastCleanupToday(
                result.at.formatted(date: .omitted, time: .shortened), moved: result.moved)
        }
        return Copy.Summary.lastCleanup(
            result.at.formatted(date: .abbreviated, time: .shortened), moved: result.moved)
    }
}

private struct RetentionSummaryRow: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsRouter.self) private var router
    @Environment(\.openSettings) private var openSettings
    @State private var isHovering = false

    var body: some View {
        let summary = RetentionSummary.of(policy: model.preferences.retention, refusal: model.retentionRefusal)
        let freed = model.preferences.totals.freedBytes
        Button {
            showSettings(.retention, router: router, openSettings: openSettings)
        } label: {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: Design.Layout.iconColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .font(Design.Typography.body)
                    if case .on = summary {
                        Text(RetentionSummary.lastCleanup(model.preferences.lastRetention, now: Date()))
                            .font(Design.Typography.cardSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    if freed > 0 {
                        Text(Copy.Summary.freed(freed.formatted(.byteCount(style: .file))))
                            .font(Design.Typography.cardSubtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Design.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card)
                .fill(isHovering ? Design.Palette.cardFillHover : Design.Palette.cardFill))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// The sibling update card: green, the whole card is the button.
private struct UpdateReadyCard: View {
    let install: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: install) {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Copy.Update.ready)
                        .font(Design.Typography.cardTitle)
                    // Wraps rather than truncates: "restart into the new version" runs long
                    // in German, Spanish and French.
                    Text(Copy.Update.restart)
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card)
                .fill(isHovering ? Design.Palette.updateFillHover : Design.Palette.updateFill))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .help(Text(Copy.Update.help))
    }
}

// MARK: - Footer

/// The line above the footer rows, as a native menu separator: native NSMenu metrics,
/// measured on macOS 26, are 11 pt for a separator item (5 + 1 + 5) and 5 pt at the menu's
/// bottom edge.
private struct FooterSeparator: View {
    /// The space above the line, kept inside the scroll view as its bottom margin, so a row
    /// cut off by the popover's height cap ends at the line rather than in mid-air.
    static let inset = Design.Layout.menuInset + Design.Spacing.s

    var body: some View {
        Rectangle()
            .fill(Design.Palette.separator)
            .frame(height: 1)
    }
}

/// Native-looking menu rows, as in VibeRes and Eject Guard.
private struct FooterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsRouter.self) private var router
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            MenuRow(icon: "folder", label: Copy.Footer.openFolder, shortcut: "⌘O",
                    isEnabled: model.screenshotFolder != nil) {
                model.openFolder()
            }
            .keyboardShortcut("o")

            MenuRow(icon: "gearshape", label: Copy.Footer.settings, shortcut: "⌘,") {
                showSettings(.general, router: router, openSettings: openSettings)
            }
            .keyboardShortcut(",")

            MenuRow(icon: "info.circle", label: Copy.Footer.about) { showAbout() }

            MenuRow(icon: "power", label: Copy.Footer.quit, shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, Design.Layout.menuInset)
    }

    /// The standard panel, as in the siblings: version, icon and what the app is for.
    private func showAbout() {
        let credits = NSAttributedString(
            string: String(localized: Copy.aboutDescription) + "\n\nMIT · github.com/m-moravcik/ClipShot",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

private struct MenuRow: View {
    let icon: String
    let label: LocalizedStringResource
    var shortcut: String?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    private var highlighted: Bool { isHovering && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: Design.Layout.iconColumn, alignment: .center)
                    .accessibilityHidden(true)
                // Two lines rather than a truncated label in a long translation.
                Text(label)
                    .font(Design.Typography.row)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Design.Spacing.s)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Layout.footerRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color.clear)
                    .padding(.horizontal, Design.Spacing.s)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(label))
    }
}
