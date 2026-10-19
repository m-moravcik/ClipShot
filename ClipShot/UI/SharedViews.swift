import SwiftUI

/// A screenshot's thumbnail at the card size, or a photo symbol when it could not be decoded.
/// Shared by the latest card and the welcome tour's Try it.
struct CaptureThumbnail: View {
    let image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 2)
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
    }
}

/// A label that may wrap, with a small switch on the right. The popover's Copy to clipboard
/// row and the welcome tour's switches.
struct SwitchRow: View {
    let title: LocalizedStringResource
    let isOn: Binding<Bool>
    var isEnabled = true
    /// A leading symbol in the icon column, as the popover rows have.
    var icon: String?
    var font: Font = Design.Typography.row

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: Design.Layout.iconColumn)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(font)
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
        .padding(.vertical, Design.Spacing.s)
    }
}

/// A small bordered-looking button whose title wraps. Used only where a native push button,
/// which keeps its title on one line, would truncate a long translation.
struct WrappingButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Design.Spacing.m)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}
