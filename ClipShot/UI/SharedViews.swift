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

/// A screenshot's thumbnail that opens the screenshot in Markup when clicked (Addendum A4).
/// A pencil appears on hover, so it is clear the picture is the thing to click.
struct MarkupThumbnail: View {
    let image: CGImage?
    let file: CaptureFile

    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        Button { model.markup(file) } label: {
            CaptureThumbnail(image: image)
                .overlay {
                    if isHovering {
                        Image(systemName: "pencil.tip.crop.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .transition(.opacity)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Design.Motion.quick, value: isHovering)
        .help(Text(Copy.Preview.markupHint))
        .accessibilityLabel(Text(Copy.Preview.editWithMarkup))
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
///
/// It draws its own keyboard focus ring: a custom style gets none from the system. Applied
/// only through `wrappingButtonStyle()`, which also turns the system focus effect off, so no
/// call site can end up with two rings.
private struct WrappingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WrappingButton(configuration: configuration)
    }

    private struct WrappingButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        /// The button's own focus: the label sits inside it.
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            configuration.label
                .font(.system(size: 11))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Design.Spacing.m)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: Design.Radius.chip + 2, style: .continuous)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                            .padding(-3)
                    }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
        }
    }
}

extension View {
    /// `WrappingButtonStyle` with the system focus effect off: the style draws its own ring.
    func wrappingButtonStyle() -> some View {
        buttonStyle(WrappingButtonStyle()).focusEffectDisabled()
    }
}

/// Text with a button on its trailing side, or the button under the text once it would take
/// more than `maxActionShare` of the row. A fixed width threshold kept a long button beside
/// a note squeezed into a narrow column in one language and stacked it in the next; a share
/// of the row reads the same in every language.
///
/// Subviews: an optional leading icon (`hasIcon`), the text, then the button. The icon sits
/// on the text's first line. Stacked, the button starts where the text does, past the icon,
/// as in the popover's attention rows; only a button wider than that column starts at the
/// row's edge, and one wider than the row (no real translation is) is offered the row's
/// width, so it truncates rather than running out of the window.
struct TrailingActionLayout: Layout {
    var hasIcon = false
    var iconSpacing: CGFloat = Design.Spacing.s
    var spacing: CGFloat = Design.Spacing.m
    var stackSpacing: CGFloat = Design.Spacing.s
    /// Side by side, the button aligns to the text's first line or to its middle.
    var alignToFirstLine = false

    static let maxActionShare: CGFloat = 0.4

    /// Whether a button `actionWidth` wide goes under the text in a row `rowWidth` wide.
    static func stacks(actionWidth: CGFloat, rowWidth: CGFloat) -> Bool {
        actionWidth > rowWidth * maxActionShare
    }

    /// Where the stacked button starts: the text column, unless the button is wider than it.
    static func stackedActionX(actionWidth: CGFloat, textX: CGFloat, rowWidth: CGFloat) -> CGFloat {
        actionWidth <= rowWidth - textX ? textX : 0
    }

    private struct Placement {
        var size: CGSize
        var icon: CGRect?
        var text: CGRect
        var action: CGRect
    }

    private func placement(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Placement {
        let icon = hasIcon ? subviews[0] : nil
        let text = subviews[hasIcon ? 1 : 0], action = subviews[hasIcon ? 2 : 1]
        let iconSize = icon?.sizeThatFits(.unspecified) ?? .zero
        let textX = icon == nil ? 0 : iconSize.width + iconSpacing
        let actionSize = action.sizeThatFits(.unspecified)
        let ideal = textX + text.sizeThatFits(.unspecified).width + spacing + actionSize.width
        let width = proposal.width ?? ideal

        var textFrame: CGRect
        var actionFrame: CGRect
        if Self.stacks(actionWidth: actionSize.width, rowWidth: width) {
            let textSize = text.sizeThatFits(ProposedViewSize(width: width - textX, height: nil))
            textFrame = CGRect(x: textX, y: 0, width: width - textX, height: textSize.height)
            let actionX = Self.stackedActionX(actionWidth: actionSize.width, textX: textX, rowWidth: width)
            actionFrame = CGRect(
                x: actionX, y: textSize.height + stackSpacing,
                width: min(actionSize.width, width - actionX), height: actionSize.height)
        } else {
            let textWidth = max(0, width - textX - spacing - actionSize.width)
            let textSize = text.sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            // The offset of each one's anchor from its top: the first baseline, or the middle.
            let textAnchor = alignToFirstLine
                ? text.dimensions(in: ProposedViewSize(width: textWidth, height: nil))[.firstTextBaseline]
                : textSize.height / 2
            let actionAnchor = alignToFirstLine
                ? action.dimensions(in: .unspecified)[.firstTextBaseline]
                : actionSize.height / 2
            let anchor = max(textAnchor, actionAnchor)
            textFrame = CGRect(x: textX, y: anchor - textAnchor, width: textWidth, height: textSize.height)
            actionFrame = CGRect(
                x: width - actionSize.width, y: anchor - actionAnchor,
                width: actionSize.width, height: actionSize.height)
        }

        var iconFrame: CGRect?
        if let icon {
            // On the text's first baseline, as an HStack aligned to it would put it.
            let textBaseline = text.dimensions(in: ProposedViewSize(textFrame.size))[.firstTextBaseline]
            let iconBaseline = icon.dimensions(in: .unspecified)[.firstTextBaseline]
            iconFrame = CGRect(origin: CGPoint(x: 0, y: textFrame.minY + textBaseline - iconBaseline), size: iconSize)
        }
        // Nothing above the top edge: shift everything down if the icon rose past it.
        let shift = max(0, -(iconFrame?.minY ?? 0))
        textFrame.origin.y += shift
        actionFrame.origin.y += shift
        iconFrame?.origin.y += shift
        let height = [textFrame.maxY, actionFrame.maxY, iconFrame?.maxY ?? 0].max() ?? 0
        return Placement(size: CGSize(width: width, height: height), icon: iconFrame, text: textFrame, action: actionFrame)
    }

    private var subviewCount: Int { hasIcon ? 3 : 2 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == subviewCount else { return .zero }
        return placement(proposal, subviews).size
    }

    /// The text's first baseline, so the row lines up with others in a form.
    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGFloat? {
        guard guide == .firstTextBaseline, subviews.count == subviewCount else { return nil }
        let p = placement(ProposedViewSize(width: bounds.width, height: nil), subviews)
        let text = subviews[hasIcon ? 1 : 0]
        return bounds.minY + p.text.minY + text.dimensions(in: ProposedViewSize(p.text.size))[.firstTextBaseline]
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == subviewCount else { return }
        let p = placement(ProposedViewSize(width: bounds.width, height: nil), subviews)
        let frames = (p.icon.map { [$0] } ?? []) + [p.text, p.action]
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A round button over a screenshot, shown on hover: the floating preview's Close, Copy again
/// and Move to Trash, and the actions on an earlier screenshot in the popover's strip. A
/// shadow and a hairline keep it apart from whatever the picture behind it is; over the
/// picture it also sits on a `HoverScrim`. The whole square around the circle takes the
/// click, so neighbouring buttons leave no dead gap between them.
struct CardButton: View {
    /// The floating preview's size.
    static let diameter: CGFloat = 22
    /// Three side by side within the strip's 64 pt thumbnail.
    static let compactDiameter: CGFloat = 20

    let symbol: String
    let label: LocalizedStringResource
    var diameter: CGFloat = Self.diameter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: (diameter * 10 / 22).rounded(), weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

/// A shade rising from a picture's bottom edge behind its hover buttons, so they read on a
/// white screenshot as on a dark one. Fill the picture with it; it draws nothing above
/// `height`.
struct HoverScrim: View {
    let height: CGFloat

    var body: some View {
        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
