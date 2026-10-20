import Foundation

/// Why retention will not run on a folder.
enum Refusal: Error, Equatable, Sendable {
    /// A system folder, the home folder or one of its ancestors, ~/Library, a volume root.
    case systemOrBroad
    /// The folder's volume has no Trash; retention never falls back to deleting.
    case noTrash
    /// The user has not seen a preview for this folder.
    case notConfirmed
    /// The screenshot folder does not exist. Only the preview reports it, so Settings and
    /// the tour say the folder is missing rather than that it has no Trash (C-1).
    case folderMissing
}

/// Refuses folders retention must never clean. Paths are resolved with realpath(3) first,
/// so trailing slashes, `.`/`..` and symlinked spellings cannot get around it.
enum FolderGuard {
    typealias TrashLookup = @Sendable (URL) -> Bool

    /// True when the folder's volume has a Trash. Never creates one.
    static let systemTrashLookup: TrashLookup = { folder in
        (try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false)) != nil
    }

    /// The folder and everything below it is refused.
    private static let systemPrefixes = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/dev", "/opt", "/cores"]
    /// Folders below these (not the roots themselves) are allowed although they live under /private.
    private static let allowedUnderPrivate = ["/private/var/folders", "/private/tmp"]

    static func refusal(for folder: URL, home: URL, hasTrash: TrashLookup = systemTrashLookup) -> Refusal? {
        refusal(resolvedPath: CaptureSettings.realPath(folder), home: home, hasTrash: hasTrash)
    }

    /// `resolvedPath` must already be resolved; it is checked as given, not resolved again.
    static func refusal(resolvedPath path: String, home: URL, hasTrash: TrashLookup = systemTrashLookup) -> Refusal? {
        if isBroad(path, home: CaptureSettings.realPath(home)) { return .systemOrBroad }
        if !hasTrash(URL(fileURLWithPath: path, isDirectory: true)) { return .noTrash }
        return nil
    }

    /// `path` must already be resolved.
    static func isBroad(_ path: String, home: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.isEmpty { return true }                                   // "/"
        if components[0] == "Users", components.count <= 2 { return true }      // /Users and every home
        if components[0] == "Volumes", components.count <= 2 { return true }    // /Volumes and its mounts
        if path == home || home.hasPrefix(path + "/") { return true }           // home and its ancestors
        if path == home + "/Library" { return true }
        if components.contains(where: { $0 == ".Trash" || $0 == ".Trashes" || $0.hasSuffix(".app") }) {
            return true
        }
        let allowed = allowedUnderPrivate.contains { path.hasPrefix($0 + "/") }
        if !allowed, systemPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        let isVolume = (try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.isVolumeKey]))?.isVolume
        return isVolume == true
    }

    /// realpath(3) of an existing path; nil when it does not resolve.
    static func strictRealPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The parent resolved, the last component kept as is (a symlinked file stays the link).
    static func canonicalPath(_ url: URL) -> String {
        let parent = CaptureSettings.realPath(url.deletingLastPathComponent())
        return (parent as NSString).appendingPathComponent(url.lastPathComponent)
    }
}
