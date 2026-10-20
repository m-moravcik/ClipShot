import Foundation

/// `clipshot`'s commands (Addendum C), carried out on the main actor through the same model
/// methods as the Shortcuts actions, so the two behave alike: the popover's selection and
/// `FileTrust`, the one clipboard write path (owner, total and Peg's copy moment), the switch
/// with its Focus rules and Peg's pause and resume, and retention's own run with all its
/// checks. Nothing changes before the welcome tour is completed.
extension AppModel {
    func handleControl(_ request: ControlRequest, appVersion: String) async -> ControlResponse {
        let log = log
        Task { await log.info("control: \(request.command.rawValue)") }
        switch request.command {
        case .status:
            return ControlResponse(status: await controlStatus(appVersion: appVersion))
        case .latest:
            let count = request.count ?? 1
            guard (1...Self.shortcutMaxCount).contains(count) else {
                return .failure(.badRequest, "The count must be 1 to \(Self.shortcutMaxCount).")
            }
            do throws(ShortcutError) {
                return ControlResponse(screenshots: try await controlLatest(count: count))
            } catch {
                return Self.controlResponse(error)
            }
        case .copy:
            if let path = request.path { return await controlCopy(path: path) }
            do throws(ShortcutError) {
                return ControlResponse(copied: try await shortcutCopyLatest().url.path)
            } catch {
                return Self.controlResponse(error)
            }
        case .pause, .resume:
            let before = preferences.copyEnabled
            do throws(ShortcutError) {
                try shortcutSetCopying(request.command == .resume)
            } catch {
                return Self.controlResponse(error)
            }
            let now = preferences.copyEnabled
            return ControlResponse(copying: ControlCopying(copying: now, changed: now != before))
        case .clean:
            do throws(ShortcutError) {
                let report = try await shortcutCleanUp(previewOnly: request.dryRun ?? false)
                return ControlResponse(cleanup: ControlCleanup(
                    dryRun: report.previewOnly, count: report.count, bytes: report.bytes,
                    files: report.files.map(\.path)))
            } catch {
                return Self.controlResponse(error)
            }
        }
    }

    /// `clipshot status`: whether copying is on, and why not (the switch by hand, a Focus,
    /// the tour), the folder, retention and the latest screenshot. Read-only, so it answers
    /// before the tour too, without touching the folder.
    func controlStatus(appVersion: String) async -> ControlStatus {
        let ready = shortcutsReady
        let watched = ready ? await watchedFolderSettled() : nil
        let latest = ready ? (try? await controlLatest(count: 1))?.first?.path : nil
        let pausedBy: ControlStatus.PausedBy? =
            if !shortcutsReady { .setup }
            else if preferences.copyEnabled { nil }
            else if pausedByFocus { .focus }
            else { .manual }
        let retention = preferences.retention
        return ControlStatus(
            running: true, appVersion: appVersion, copying: shortcutsReady && preferences.copyEnabled,
            pausedBy: pausedBy, folder: shortcutsReady ? (screenshotFolder ?? watched)?.path : nil,
            retention: ControlStatus.Retention(
                enabled: retention.enabled, days: retention.days,
                refusal: retention.enabled ? retentionRefusal?.controlName : nil),
            latest: latest)
    }

    /// `clipshot latest`: Get Recent Screenshots' choice (the popover's selection, a file
    /// `FileTrust` refuses skipped for the next newest), as paths.
    func controlLatest(count: Int) async throws(ShortcutError) -> [ControlScreenshot] {
        guard shortcutsReady else { throw .notSetUp }
        let candidates = await recentScreenshots(count: Self.shortcutMaxCount)
        let files = await Task.detached(priority: .userInitiated) {
            ControlScreenshots.trusted(candidates, count: count)
        }.value
        guard !files.isEmpty else { throw .noScreenshots }
        return files.map(ControlScreenshots.info)
    }

    /// `clipshot copy PATH`: the row's Copy (`copyExplicitly`) for a file directly in the
    /// watched folder that `FileTrust` would read. Anything else is refused and says why.
    func controlCopy(path: String) async -> ControlResponse {
        guard shortcutsReady else { return Self.controlResponse(.notSetUp) }
        guard path.hasPrefix("/") else { return .failure(.badRequest, "The path must be absolute.") }
        guard let folder = await watchedFolderSettled() else { return Self.controlResponse(.notSetUp) }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let checked = await Task.detached(priority: .userInitiated) { Self.copyable(url, in: folder) }.value
        switch checked {
        case .failure(let failure):
            return ControlResponse(error: failure)
        case .success(let file):
            guard await copyExplicitly(file) else { return Self.controlResponse(.copyFailed) }
            return ControlResponse(copied: file.url.path)
        }
    }

    /// `url` as a file `clipshot copy` may copy: directly in `folder` (after resolving the
    /// folder's symlinks; the file itself is never followed), an image ClipShot copies, and
    /// readable through `FileTrust` (a regular file of this user, not too large).
    nonisolated static func copyable(_ url: URL, in folder: URL) -> Result<CaptureFile, ControlFailure> {
        guard let resolved = FolderGuard.strictRealPath(folder.path),
              (FolderGuard.canonicalPath(url) as NSString).deletingLastPathComponent == resolved
        else {
            return .failure(ControlFailure(
                code: .notInFolder,
                message: "\(url.path) is not in the screenshot folder, \(folder.path). "
                    + "clipshot copies only files directly in it."))
        }
        var st = stat()
        if lstat(url.path, &st) != 0, errno == ENOENT {
            return .failure(ControlFailure(code: .refusedFile, message: "No such file: \(url.path)"))
        }
        guard let file = CaptureFile.inspect(url) else {
            return .failure(ControlFailure(
                code: .refusedFile,
                message: "\(url.lastPathComponent) is not an image file ClipShot copies "
                    + "(a regular png, jpg, heic, tiff or pdf file, not a symlink)."))
        }
        if case .failure(let refusal) = FileTrust.open(url) {
            return .failure(ControlFailure(
                code: .refusedFile, message: "ClipShot does not read \(url.lastPathComponent): \(refusal.rawValue)."))
        }
        return .success(file)
    }

    /// A Shortcuts refusal as `clipshot` reports it: the same English words.
    static func controlResponse(_ error: ShortcutError) -> ControlResponse {
        let message = error.message.key
        switch error {
        case .notSetUp: return .failure(.notSetUp, message)
        case .noScreenshots: return .failure(.noScreenshots, message)
        case .copyFailed: return .failure(.copyFailed, message)
        case .retentionOff: return .failure(.retentionOff, message)
        case .retentionChanged: return .failure(.retentionChanged, message)
        case .retentionRefused(let refusal):
            let reason = switch refusal {
            case .notConfirmed: ""
            case .systemOrBroad: ": it is a system or home-level folder."
            case .noTrash: ": its volume has no Trash."
            case .folderMissing: ": the folder does not exist."
            }
            return .failure(.retentionRefused, message + reason)
        }
    }
}
