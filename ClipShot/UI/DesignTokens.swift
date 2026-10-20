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
        /// An outcome that appears next to the control that caused it, such as Clean up now's
        /// "Moved N screenshots": a crossfade, so it does not pop in. Also under Reduce Motion.
        static let outcome: Animation = quick

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
        /// Moments after the copy the badge bounces, with the menu bar animation.
        static let badgeDelay: Duration = .milliseconds(120)

        // The menu bar copy animation (`Peg`): every copy confirms itself in the menu bar,
        // playful and clearly noticeable: the new card is pinned slowly enough to follow in
        // the corner of the eye, and it is all over in 2.4 s, as VibeRes's switch animation.
        // A MenuBarExtra label is a static image, so it is drawn frame by frame on a timer
        // that runs only while it plays (`CopiedFlash`).

        /// The whole animation, from the first frame back to rest.
        static let menuBarCopy: TimeInterval = 2.4
        /// Frames per second while it plays: smooth for small moves, 72 redraws per copy.
        static let menuBarFrameRate: Double = 30
        /// Reduce Motion: the copied pose, held, with no movement.
        static let menuBarHold: TimeInterval = 1.4

        // The tour's Try it: the first real copy is the strongest moment in the app.

        /// The success check bounces once as the new card slides in on the menu bar line
        /// (`Peg.Beat.slideIn`), so the two read as one event. Reduce Motion: no bounce.
        static let successBounceDelay: Duration = .milliseconds(300)
        /// Faster than the system bounce, so the peak stays well under half a second.
        static let successBounceSpeed: Double = 1.5

        // The popover's failure note (A6), said where an Undo or a Move to Trash did not
        // happen. Reduce Motion: `quick` crossfades. The list of recent screenshots, with its
        // Undo strip in place of a trashed row, moves on `layout`.

        /// The rows under the note make room for it, or close up after it.
        static let noteSpring = Spring(duration: 0.32, bounce: 0.18)
        static let noteMakeRoom: Animation = .spring(noteSpring)
        /// The note drops in from just above; it leaves by fading, faster.
        static let noteIn: Animation = .spring(duration: 0.3, bounce: 0.22)
        static let noteDrop: CGFloat = 8

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
