import ImageIO
import SwiftUI

/// The latest copied screenshot and its thumbnail, decoded off the main actor.
struct LatestCapture: Identifiable, Equatable, @unchecked Sendable {
    /// Twice the card's 64 pt, for Retina.
    static let thumbnailPixels = 128

    let file: CaptureFile
    /// nil when the file could not be decoded (a PDF, or a file already gone).
    let thumbnail: CGImage?

    var id: CaptureFile { file }

    static func == (a: LatestCapture, b: LatestCapture) -> Bool {
        a.file == b.file && a.thumbnail === b.thumbnail
    }
}

enum Thumbnailer {
    /// A downscaled image, decoded now rather than at first draw. Synchronous file IO.
    nonisolated static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The latest screenshot, or a quiet line before the first copy. Swaps cards with a
/// crossfade only once the new thumbnail is decoded, so it never flashes empty.
struct LatestCaptureSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let latest = model.latest {
                LatestCaptureCard(capture: latest)
                    .id(latest.id)
                    .transition(.opacity)
            } else {
                Text(Copy.Latest.none)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                    .transition(.opacity)
            }
        }
        // A crossfade, which Reduce Motion keeps.
        .animation(Design.Motion.quick, value: model.latest?.id)
    }
}

struct LatestCaptureCard: View {
    let capture: LatestCapture

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showCheck = false

    private static let checkDuration: Duration = .milliseconds(1_200)

    private var size: String {
        capture.file.size.formatted(.byteCount(style: .file))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.m) {
            HStack(spacing: Design.Spacing.m) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: capture.file.url.lastPathComponent)
                        .font(Design.Typography.cardTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: Design.Spacing.s) {
                        Text(capture.file.created, style: .relative)
                        Text(verbatim: "·")
                        Text(verbatim: size)
                    }
                    .font(Design.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Copy.Latest.accessibility(
                age: capture.file.created.formatted(.relative(presentation: .named)), size: size)))
            .accessibilityAddTraits(.isImage)

            HStack(spacing: Design.Spacing.s) {
                Button { copyAgain() } label: {
                    Label {
                        Text(Copy.Action.copyAgain)
                    } icon: {
                        Image(systemName: showCheck ? "checkmark" : "doc.on.doc")
                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    }
                }
                Button { model.revealLast() } label: {
                    Label { Text(Copy.Action.showInFinder) } icon: { Image(systemName: "folder") }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.vertical, Design.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
        Group {
            if let image = capture.thumbnail {
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

    private func copyAgain() {
        Task {
            guard await model.copyAgain() else { return }
            withAnimation(Design.Motion.quick) { showCheck = true }
            try? await Task.sleep(for: Self.checkDuration)
            withAnimation(Design.Motion.quick) { showCheck = false }
        }
    }
}
