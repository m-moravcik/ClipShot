import AppKit

/// Markup, the editing action on a screenshot that ClipShot shows (Addendum A4). Move to
/// Trash and Undo (A6) live in AppModel.swift, beside the state only they may change (R-3).
extension AppModel {
    // MARK: - Markup

    /// After the editor closes, the session stays this long, so the write that Done made is
    /// still copied by the rescans that follow it (the last is 3 s after an event).
    static let editGrace: Duration = .seconds(5)

    func reveal(_ file: CaptureFile) {
        workspace.reveal(file.url)
    }

    /// Opens `file` for annotation in Markup. While it is open, a save copies the edited image
    /// even when the file is older than the 30 s copy window.
    func markup(_ file: CaptureFile) {
        let session = edits.begin(file)
        let log = log
        openMarkup(file.url) { [weak self] result in
            Task { await log.info("markup \(result.logName)") }
            guard let self else { return }
            switch result {
            case .savedCopy(let data):
                self.copyEdited(data)
                self.endEdit(session)
            case .savedInPlace, .closed, .failed:
                self.endEdit(session)
            case .openedInPreview:
                // Preview never says when it closes: the session lasts its 30 minutes.
                break
            }
        }
    }

    /// Ends only the session that finished: reopening the same file meanwhile keeps the new one.
    private func endEdit(_ session: EditSession.Token) {
        let edits = edits
        Task {
            try? await Task.sleep(for: Self.editGrace)
            edits.end(session)
        }
    }

    /// The editor returned an edited copy instead of writing the file: copy that image, as a
    /// save in place would be copied, so not while copying is paused (`CopyOrigin.edited`).
    private func copyEdited(_ data: Data) {
        guard preferences.copyEnabled else { return }
        Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { PNGConverter.pngData(fromImageData: data) }.value
            guard let self, let png else { return }
            _ = self.writeClipboard(png, .edited)
        }
    }
}

/// A Move to Trash or an Undo that did not happen, and why, in the user's words.
enum ScreenshotActionFailure: Equatable, Sendable {
    case trash(AppModel.TrashError)
    case undo

    var message: LocalizedStringResource {
        switch self {
        case .trash(.notTracked): Copy.Failure.notTracked
        case .trash(.outsideFolder): Copy.Failure.outsideFolder
        case .trash(.noTrash): Copy.Failure.noTrash
        case .trash(.failed): Copy.Failure.trashFailed
        case .undo: Copy.Failure.undoFailed
        }
    }
}
