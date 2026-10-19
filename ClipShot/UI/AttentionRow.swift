import AppKit
import SwiftUI

/// What a button on an attention row does. Each is named for its effect.
enum AttentionAction: Hashable, Identifiable, Sendable {
    case saveToFile, chooseFolder, openPrivacySettings, copyAgain, report, review

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .saveToFile: Copy.Action.saveToFile
        case .chooseFolder: Copy.Action.chooseFolder
        case .openPrivacySettings: Copy.Action.openPrivacySettings
        case .copyAgain: Copy.Action.copyAgain
        case .report: Copy.Action.report
        case .review: Copy.Action.review
        }
    }
}

/// The words and buttons of one attention row. Pure, so the copy can be tested.
struct AttentionPresentation {
    let message: LocalizedStringResource
    let actions: [AttentionAction]

    static func of(_ attention: Attention, destination: CaptureDestination) -> AttentionPresentation {
        switch attention {
        case .destinationNotFile:
            // The spec's sentence is about the clipboard, by far the usual case; an app
            // destination (Preview, Mail) gets its own, true sentence.
            let message = if case .other = destination {
                Copy.Attention.destinationOther
            } else {
                Copy.Attention.destinationClipboard
            }
            return .init(message: message, actions: [.saveToFile])
        case .folderMissing(let url):
            return .init(message: Copy.Attention.folderMissing(displayName(url)), actions: [.chooseFolder])
        case .folderAccessDenied(let url):
            return .init(
                message: Copy.Attention.folderAccessDenied(displayName(url)),
                actions: [.openPrivacySettings, .chooseFolder])
        case .couldNotCopy:
            return .init(message: Copy.Attention.couldNotCopy, actions: [.copyAgain, .report])
        case .retentionFolderChanged(let url):
            return .init(message: Copy.Attention.retentionFolderChanged(displayName(url)), actions: [.review])
        case .noTrash(let url):
            return .init(message: Copy.Attention.noTrash(displayName(url)), actions: [])
        }
    }

    /// The top row, plus every row once expanded, and how many are left out.
    static func visible(_ attentions: [Attention], expanded: Bool) -> (rows: [Attention], hidden: Int) {
        if expanded || attentions.count <= 1 { return (attentions, 0) }
        return (Array(attentions.prefix(1)), attentions.count - 1)
    }

    /// The folder's own name; "/" for the root.
    static func displayName(_ url: URL) -> String {
        let name = url.standardizedFileURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }
}

/// Something the user should fix, with buttons that fix it.
struct AttentionRow: View {
    let attention: Attention

    @Environment(AppModel.self) private var model
    @Environment(SettingsRouter.self) private var router
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        let presentation = AttentionPresentation.of(attention, destination: model.destination)
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(presentation.message)
                    .font(Design.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !presentation.actions.isEmpty {
                // Side by side; stacked when a translation makes them wider than the row; and
                // only if one title alone is still too wide, buttons whose titles wrap.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Design.Spacing.s) { buttons(presentation.actions) }
                    VStack(alignment: .leading, spacing: Design.Spacing.s) { buttons(presentation.actions) }
                    VStack(alignment: .leading, spacing: Design.Spacing.s) {
                        buttons(presentation.actions, wrapping: true)
                    }
                }
                .padding(.leading, Design.Layout.iconColumn + Design.Spacing.m)
            }
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.attentionFill))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func buttons(_ actions: [AttentionAction], wrapping: Bool = false) -> some View {
        ForEach(actions) { action in
            if wrapping {
                Button { perform(action) } label: { Text(action.title) }
                    .buttonStyle(WrappingButtonStyle())
            } else {
                Button { perform(action) } label: { Text(action.title) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    private func perform(_ action: AttentionAction) {
        switch action {
        case .saveToFile:
            Task { await model.fixDestination() }
        case .chooseFolder:
            guard let url = FolderPicker.choose(startingAt: model.screenshotFolder) else { return }
            Task {
                do {
                    try await model.setFolder(url)
                } catch {
                    // The popover closed for the panel; Settings shows why, next to the folder.
                    showSettings(.capture, router: router, openSettings: openSettings)
                }
            }
        case .openPrivacySettings:
            model.openPrivacySettings()
        case .copyAgain:
            Task { await model.copyAgain() }
        case .report:
            Task { openURL(await model.reportIssueURL()) }
        case .review:
            showSettings(.retention, router: router, openSettings: openSettings)
        }
    }
}

/// The folder picker shared by the popover and Settings.
@MainActor
enum FolderPicker {
    static func choose(startingAt folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = String(localized: Copy.Capture.choosePrompt)
        panel.message = String(localized: Copy.Capture.chooseMessage)
        // A menu bar app is not active; without this the panel opens behind other windows.
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Opens Settings on `tab`. ClipShot has no Dock icon, so the window needs the app activated
/// first or it opens behind whatever the user is working in.
@MainActor
func showSettings(_ tab: SettingsTab, router: SettingsRouter, openSettings: OpenSettingsAction) {
    router.tab = tab
    NSApp.activate()
    openSettings()
}
