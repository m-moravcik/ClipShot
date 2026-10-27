import Foundation

/// Hidden files seen while fresh, so a capture macOS renames into place late is still copied.
///
/// macOS writes every capture under a hidden temporary name and renames it into place (spike
/// F4), normally within milliseconds. On 2026-10-27 Spotlight held `screencapture` up for 69 s
/// between the write and the rename: the file then appeared with a birth time far outside the
/// copy window. A rename keeps the inode and the birth time, so the final file is recognised by
/// both, and the window counts from the moment it appeared (`CopyDecider.isFresh(hiddenFor:)`).
/// A file that was never seen under a hidden name, such as one put back from the Trash, is
/// judged by its own times as before.
struct StagedCaptures: Sendable {
    /// How long a file may stay hidden and still count as late rather than old.
    static let limit: TimeInterval = 600

    private struct Entry: Sendable {
        let created: Date
        let seen: Date
        /// Fixed by the first listing under the final name.
        var hiddenFor: TimeInterval?
    }

    private var entries: [Data: Entry] = [:]

    /// Records a hidden file the first time it is seen, if it is this user's and fresh.
    mutating func saw(_ temporary: CaptureFile, now: Date) {
        guard entries[temporary.resourceID] == nil, temporary.isOwnedByUser,
              CopyDecider.isFresh(temporary, now: now)
        else { return }
        entries[temporary.resourceID] = Entry(created: temporary.created, seen: now)
    }

    /// How long `file` was hidden before it appeared under its own name; 0 when it was never
    /// seen hidden, its inode now belongs to another file, or it stayed hidden past `limit`.
    func hiddenFor(_ file: CaptureFile, now: Date) -> TimeInterval {
        guard let entry = entries[file.resourceID], entry.created == file.created else { return 0 }
        let hidden = entry.hiddenFor ?? now.timeIntervalSince(entry.seen)
        return (0...Self.limit).contains(hidden) ? hidden : 0
    }

    /// Fixes what the first listing under the final name measured, so the rescans after it
    /// count the copy window from the same moment.
    mutating func appeared(_ file: CaptureFile, hiddenFor: TimeInterval) {
        guard var entry = entries[file.resourceID], entry.created == file.created, entry.hiddenFor == nil
        else { return }
        entry.hiddenFor = hiddenFor
        entries[file.resourceID] = entry
    }

    /// Forgets a file that never appeared within `limit`, and one that appeared once the copy
    /// window and the decider's memory of it have passed.
    mutating func prune(now: Date) {
        entries = entries.filter { _, entry in
            guard let hidden = entry.hiddenFor else { return now.timeIntervalSince(entry.seen) <= Self.limit }
            return now.timeIntervalSince(entry.seen) - hidden <= CopyDecider.memory
        }
    }
}
