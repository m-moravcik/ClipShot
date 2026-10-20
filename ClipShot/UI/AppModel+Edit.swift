import AppKit

/// Markup and Move to Trash, the actions on a screenshot that ClipShot shows (Addendum A4, A6).
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

    /// The editor returned an edited copy instead of writing the file: copy that image, unless
    /// copying is paused (then nothing ClipShot does on its own writes the clipboard).
    private func copyEdited(_ data: Data) {
        guard preferences.copyEnabled else { return }
        Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { PNGConverter.pngData(fromImageData: data) }.value
            guard let self, self.preferences.copyEnabled, let png, self.pasteboard.writePNG(png) else { return }
            self.changeCountAfterCopy = self.pasteboard.changeCount
            self.startFlash()
            if self.preferences.copySound { self.playSound() }
            self.announce(Copy.screenshotCopied)
        }
    }

    // MARK: - Trash

    enum TrashError: Error, Equatable {
        /// Not a screenshot ClipShot saw being taken (or one the user adopted).
        case notTracked
        /// Not a direct child of the screenshot folder, or the folder is one ClipShot never
        /// touches.
        case outsideFolder
        /// The folder's volume has no Trash; ClipShot never deletes instead.
        case noTrash
        /// The file changed since, or the Trash refused it.
        case failed
    }

    struct TrashedScreenshot {
        let original: URL
        let inTrash: URL
    }

    /// Moves a screenshot to the Trash: only a file in the ledger, only a direct child of the
    /// watched folder, with retention's folder guard (realpath, not a broad folder, the volume
    /// has a Trash), and only through `FileManager.trashItem`. No confirmation: it can be put
    /// back.
    func trash(_ file: CaptureFile) async throws(TrashError) {
        guard let folder = watchedFolder else { throw .outsideFolder }
        let path = FolderGuard.canonicalPath(file.url)
        guard await ledger.contains(path: path, resourceID: file.resourceID) else { throw .notTracked }
        let home = home
        let trasher = trasher
        let hasTrash = hasTrash
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL?, TrashError> in
            // The folder resolves, passes retention's guard, and is the file's resolved
            // parent: a direct child, whatever spelling the URL had.
            guard let resolved = FolderGuard.strictRealPath(folder.path),
                  (path as NSString).deletingLastPathComponent == resolved
            else { return .failure(.outsideFolder) }
            switch FolderGuard.refusal(resolvedPath: resolved, home: home, hasTrash: hasTrash) {
            case .systemOrBroad?, .notConfirmed?: return .failure(.outsideFolder)
            case .noTrash?: return .failure(.noTrash)
            case nil: break
            }
            guard let current = CaptureFile.inspect(file.url), current.resourceID == file.resourceID else {
                return .failure(.failed)
            }
            do {
                return .success(try trasher.trash(current.url))
            } catch {
                return .failure(.failed)
            }
        }.value
        let inTrash: URL?
        do throws(TrashError) {
            inTrash = try outcome.get()
        } catch {
            throw error
        }
        await ledger.remove(path: path, resourceID: file.resourceID)
        lastTrashed = inTrash.map { TrashedScreenshot(original: file.url, inTrash: $0) }
        previews.dismiss(file: file, .trash)
        preferences.totals.trashed += 1
        let ext = file.url.pathExtension.lowercased()
        let log = log
        Task { await log.info("trashed ext=\(ext)") }
    }

    /// Puts the screenshot last moved to the Trash back where it was, and back in the ledger.
    /// False when there is nothing to undo, or its place is taken.
    @discardableResult
    func undoTrash() async -> Bool {
        guard let trashed = lastTrashed else { return false }
        lastTrashed = nil
        let restored = await Task.detached(priority: .userInitiated) { () -> CaptureFile? in
            guard !FileManager.default.fileExists(atPath: trashed.original.path) else { return nil }
            do {
                try FileManager.default.moveItem(at: trashed.inTrash, to: trashed.original)
            } catch {
                return nil
            }
            return CaptureFile.inspect(trashed.original)
        }.value
        guard let restored else { return false }
        await ledger.adopt([restored])
        preferences.totals.trashed = max(0, preferences.totals.trashed - 1)
        return true
    }
}
