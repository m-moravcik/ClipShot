import Foundation

/// What shows after a screenshot (spec Addendum A1). With the macOS floating thumbnail on,
/// macOS writes the file only when the thumbnail goes away, about 6 s later; with it off the
/// file appears in about 150 ms (spike F-latency). So instant copy and the macOS thumbnail
/// exclude each other.
enum PreviewMode: String, CaseIterable, Codable, Sendable {
    /// The macOS thumbnail off, instant copy, and ClipShot's own floating preview.
    case clipShot
    /// The macOS thumbnail on: copying waits until the thumbnail disappears.
    case macOS
    /// The macOS thumbnail off, instant copy, no preview.
    case none

    /// The mode in effect. The system pref wins: when the user turns "Show Floating Thumbnail"
    /// on in Cmd+Shift+5 > Options, ClipShot reads it as macOS and never flips it back. A
    /// stored macOS whose thumbnail was turned off elsewhere copies at once and shows
    /// ClipShot's preview, the default.
    static func effective(stored: PreviewMode, showThumbnail: Bool) -> PreviewMode {
        if showThumbnail { return .macOS }
        return stored == .macOS ? .clipShot : stored
    }

    /// The `show-thumbnail` value this mode needs.
    var showsSystemThumbnail: Bool { self == .macOS }

    var showsOwnPreview: Bool { self == .clipShot }

    /// The copy lands the moment the file appears.
    var copiesInstantly: Bool { self != .macOS }
}
