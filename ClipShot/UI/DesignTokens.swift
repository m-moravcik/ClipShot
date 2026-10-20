import SwiftUI

/// Single source of truth for spacing, radii, typography and colors.
/// Centralised so future tweaks don't sprawl across views.
enum Design {
    enum Spacing {
        static let xs: CGFloat = 2
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
    }

    enum Radius {
        static let chip: CGFloat = 5
        static let card: CGFloat = 8
        static let popover: CGFloat = 10
    }

    enum Layout {
        static let popoverWidth: CGFloat = 300
        static let popoverMaxHeight: CGFloat = 600
        static let rowVerticalPadding: CGFloat = 4
        static let chipMinWidth: CGFloat = 24
        /// A 13pt line plus 4 + 4 is 24pt, the height of a native menu item on
        /// macOS 26 (measured with `NSMenu.size`), as Eject Guard uses too.
        static let footerRowVerticalPadding: CGFloat = 4
        /// Space a native menu keeps around a separator and at its edges.
        static let menuInset: CGFloat = 5
        /// The leading symbol column of footer rows and attention rows, as in Eject Guard.
        static let iconColumn: CGFloat = 16
        static let thumbnailSize = CGSize(width: 64, height: 44)
        /// The Settings window, the same size as VibeRes and Eject Guard.
        static let settingsSize = CGSize(width: 470, height: 400)
    }

    enum Typography {
        static let cardTitle: Font = .system(size: 13, weight: .semibold)
        static let cardSubtitle: Font = .system(size: 11).monospacedDigit()
        static let badge: Font = .system(size: 9, weight: .bold)
        static let navTitle: Font = .system(size: 13, weight: .semibold)
        static let footer: Font = .system(size: 11)
        /// Outcome notes and other secondary annotations under a control.
        ///
        /// 11pt, not 10: macOS treats 11pt as the floor for text that carries
        /// meaning, and these sizes were being rendered in `.secondary` and
        /// `.tertiary`, which takes the contrast down with them.
        static let note: Font = .system(size: 11)
        /// All-caps section labels ("PROFILES", "ENTRIES").
        static let sectionHeader: Font = .system(size: 10, weight: .semibold, design: .rounded)
        /// Inline buttons and pickers inside the popover.
        static let control: Font = .system(size: 12, weight: .medium)
        /// Sentences in popover rows, such as attention messages: a size down from menu rows
        /// so a two-clause message fits the 300 pt popover in three lines.
        static let body: Font = .system(size: 12)
        /// Footer menu rows and the toggle label, the size of a native menu item.
        static let row: Font = .system(size: 13)
    }

    enum Palette {
        /// Subtle surface tint that adapts to light/dark.
        static let cardFill = Color.secondary.opacity(0.10)
        static let cardFillHover = Color.secondary.opacity(0.18)
        static let chipFill = Color.secondary.opacity(0.16)
        static let rowSelectedFill = Color.accentColor.opacity(0.12)
        static let rowSelectedTint = Color.accentColor
        static let separator = Color.secondary.opacity(0.15)
        /// The update-ready card, the same green wash as VibeRes and Eject Guard.
        static let updateFill = Color.green.opacity(0.10)
        static let updateFillHover = Color.green.opacity(0.18)
        /// Attention rows: a warm wash behind the warning triangle.
        static let attentionFill = Color.orange.opacity(0.12)
    }

    enum Motion {
        static let quick: Animation = .easeInOut(duration: 0.18)
        static let layout: Animation = .smooth(duration: 0.2)
        static let number: Animation = .smooth(duration: 0.25)

        // The floating preview (Addendum A3): playful, each with a job, all settled within
        // about 0.45 s. Reduce Motion replaces every one of them with `quick` crossfades.

        /// Arrival from the screen edge, with a little overshoot: shows where the copy is.
        static let arriveSpring = Spring(duration: 0.42, bounce: 0.32)
        static let arrive: Animation = .spring(arriveSpring)
        /// The image settles into the card a beat after the card lands.
        static let landSpring = Spring(duration: 0.34, bounce: 0.38)
        static let landDelay: TimeInterval = 0.06
        static let land: Animation = .spring(landSpring).delay(landDelay)
        /// Older previews make room above a new one.
        static let stackSpring = Spring(duration: 0.36, bounce: 0.2)
        static let stack: Animation = .spring(stackSpring)
        /// A swipe that does not go far enough springs back past its rest point once.
        static let snapBack: Animation = .spring(duration: 0.32, bounce: 0.4)
        /// Leaving on time or on Close: exits are faster than arrivals.
        static let leave: Animation = .smooth(duration: 0.24)
        /// Move to Trash: shrink and drop, accelerating like something falling.
        static let dropDuration: TimeInterval = 0.24
        static let drop: Animation = .easeIn(duration: dropDuration)
        /// Moments after the copy the badge bounces, with the menu bar flash.
        static let badgeDelay: Duration = .milliseconds(120)

        /// A swipe released at `velocity` (points per second) flings out along `distance`
        /// with that speed, then settles without bounce.
        static func fling(velocity: CGFloat, distance: CGFloat) -> Animation {
            .interpolatingSpring(flingSpring, initialVelocity: flingVelocity(velocity, distance: distance))
        }
        static let flingSpring = Spring(mass: 1, stiffness: 260, damping: 32)
        /// After this much of a fling the preview is off screen and leaves the stack.
        static let flingHandOff: Duration = .milliseconds(200)
        /// The release speed relative to the distance left, as a spring's initial velocity.
        static func flingVelocity(_ velocity: CGFloat, distance: CGFloat) -> Double {
            distance > 0 ? Double(max(0, velocity) / distance) : 0
        }
    }
}
