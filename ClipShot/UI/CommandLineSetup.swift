import AppKit
import Foundation
import Observation

// Settings > General > Command line: whether `clipshot` is on the PATH, and Install, which
// links /usr/local/bin/clipshot to the tool inside this app through the macOS password
// prompt, as editors do for their shell commands. Detection reads only the paths in
// `CommandLineLocations`, so tests and the render harness point it at folders of their own.

/// Where `clipshot` may be, and where Install puts it.
struct CommandLineLocations: Sendable {
    /// The tool inside the running app, as the link should name it (not resolved: a link to
    /// /Applications/ClipShot.app keeps working when Sparkle replaces the bundle).
    var helper: URL
    /// Where a `clipshot` may be found: Homebrew's bin, /usr/local/bin and ~/.local/bin, in
    /// the order a shell usually searches them.
    var candidates: [URL]
    /// Where Install creates the link.
    var installTarget: URL
    /// The Homebrew cask installed this copy and links the tool itself: no Install.
    var isHomebrewCopy: Bool
    /// Shown as "~".
    var home: URL
    /// Tests and the render harness: a folder that stands for "/", so paths in it are shown
    /// as the real ones would be.
    var displayRoot: URL?

    static let toolName = "clipshot"
    static let installFolder = "/usr/local/bin"

    /// The running app's locations.
    static func live(
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CommandLineLocations {
        var folders: [String] = []
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            folders.append(URL(fileURLWithPath: prefix).appending(path: "bin").path)
        }
        folders += ["/opt/homebrew/bin", installFolder, home.appending(path: ".local/bin").path]
        var seen = Set<String>()
        let candidates = folders.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
            .map { URL(fileURLWithPath: $0).appending(path: toolName) }
        return CommandLineLocations(
            helper: bundleURL.appending(path: "Contents/Helpers/\(toolName)"),
            candidates: candidates,
            installTarget: URL(fileURLWithPath: installFolder).appending(path: toolName),
            isHomebrewCopy: UpdaterGate.isHomebrewCopy(
                bundleURL: bundleURL, caskroomBundleURLs: UpdaterGate.caskroomBundleURLs(environment: environment)),
            home: home)
    }

    /// `url` for display: the home folder as "~".
    func display(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        let home = home.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        if let root = displayRoot?.standardizedFileURL.path, path.hasPrefix(root + "/") {
            path = String(path.dropFirst(root.count))
        }
        return path
    }

    /// The command that links the tool by hand, for Copy Command: the same link Install makes.
    var manualCommand: String {
        let folder = installTarget.deletingLastPathComponent().path
        return "sudo mkdir -p \(Self.shellQuoted(folder)) && sudo ln -s \(Self.shellQuoted(helper.path)) "
            + Self.shellQuoted(installTarget.path)
    }

    /// `text` as one word for a POSIX shell: in single quotes, a single quote as '\''. A
    /// plain path such as /usr/local/bin is left as it is, so the command reads naturally.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What one candidate path holds. Read with `lstat`, the link itself never followed except to
/// see where it ends.
enum CommandLineEntry: Equatable, Sendable {
    case absent
    /// A symlink that resolves to this app's tool.
    case linked
    /// A symlink to nothing: an app that was moved or deleted.
    case broken(target: String)
    /// A symlink to the tool of another ClipShot.app.
    case otherCopy(target: String)
    /// Anything else: a copy from `make install-cli`, another program, a folder.
    case foreign

    static func inspect(_ url: URL, helper resolvedHelper: String) -> CommandLineEntry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .absent }
        guard info.st_mode & S_IFMT == S_IFLNK else { return .foreign }
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
        guard let resolved = CommandLineStatus.resolvedPath(url.path) else { return .broken(target: target) }
        if resolved == resolvedHelper { return .linked }
        if resolved.hasSuffix(".app/Contents/Helpers/\(CommandLineLocations.toolName)") {
            return .otherCopy(target: target)
        }
        return .foreign
    }
}

/// What Settings > General shows for the command line.
enum CommandLineStatus: Equatable, Sendable {
    /// This copy has no tool to link (not an app bundle, or the tool is missing).
    case unavailable
    /// Running from App Translocation (opened from Downloads without moving): a link to it
    /// would break at the next launch.
    case needsMove
    /// The Homebrew cask owns the link: never offer to make one. The link it made, if found.
    case homebrew(URL?)
    case linked(URL)
    case notInstalled
    /// A link to a missing or another ClipShot: offered to fix, after a confirmation.
    case stale(URL, target: String, missing: Bool)
    /// Something else named clipshot, never replaced.
    case foreign(URL)

    /// In order: a Homebrew copy, a stale link anywhere (it may come first on the PATH),
    /// a link to this app, something else, nothing.
    static func detect(_ locations: CommandLineLocations) -> CommandLineStatus {
        guard let helper = resolvedPath(locations.helper.path),
              FileManager.default.isExecutableFile(atPath: helper)
        else { return .unavailable }
        let found = locations.candidates.map { ($0, CommandLineEntry.inspect($0, helper: helper)) }
        let linked = found.first { $0.1 == .linked }?.0
        if locations.isHomebrewCopy { return .homebrew(linked) }
        if locations.helper.path.contains("/AppTranslocation/") { return .needsMove }
        for (url, entry) in found {
            switch entry {
            case .broken(let target): return .stale(url, target: target, missing: true)
            case .otherCopy(let target): return .stale(url, target: target, missing: false)
            case .absent, .linked, .foreign: continue
            }
        }
        if let linked { return .linked(linked) }
        if let foreign = found.first(where: { $0.1 == .foreign }) { return .foreign(foreign.0) }
        return .notInstalled
    }

    /// Where Install or Fix makes the link, and what must be there now: nil for nothing, else
    /// the stale link's target. Nil when there is nothing to do.
    func action(installTarget: URL) -> (link: URL, replacing: String?)? {
        switch self {
        case .notInstalled: (installTarget, nil)
        case .stale(let url, let target, _): (url, target)
        case .unavailable, .needsMove, .homebrew, .linked, .foreign: nil
        }
    }

    /// `realpath`: every link resolved, nil when the path ends nowhere.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// How a link attempt ended.
enum CommandLineLinkResult: Equatable, Sendable {
    case linked
    /// The password prompt was cancelled.
    case cancelled
    /// Something appeared at the path, or the link changed, after it was checked.
    case changed
    /// The tool is not in the app.
    case noTool
    /// The system's message, in English.
    case failed(String)
}

protocol CommandLineLinking: Sendable {
    /// Links `link` to `helper`. With `replacing` nil nothing may be at `link`; otherwise it
    /// must be a symlink whose target is exactly `replacing`.
    func link(
        helper: URL, at link: URL, replacing: String?, asAdministrator: Bool, prompt: String
    ) async -> CommandLineLinkResult
}

/// Links through `osascript`'s `do shell script`, `with administrator privileges` when the
/// folder is not the user's: the standard macOS password prompt. Out of process, so the app
/// keeps copying screenshots while the prompt is open.
///
/// No path is ever spliced into a script: the paths reach osascript as arguments, AppleScript
/// quotes each with `quoted form of`, and the shell script reads them as `$1`, `$2`, `$3`.
struct ScriptLinker: CommandLineLinking {
    /// Exit codes of `shellScript`, which `do shell script` reports as the error number.
    enum Exit {
        static let noTool = 64
        static let changed = 66
        static let failed = 70
    }

    /// Run by /bin/sh, as root behind the prompt. Creates the folder; with no expected target,
    /// refuses anything at the path (ln without -f never replaces); with one, replaces only
    /// that very symlink, by rename. Nothing is deleted.
    static let shellScript = """
        helper=$1 link=$2 expected=$3
        dir=${link%/*}
        [ -f "$helper" ] && [ -x "$helper" ] || exit \(Exit.noTool)
        /bin/mkdir -p -- "$dir" || exit \(Exit.failed)
        if [ -z "$expected" ]; then
          if [ -e "$link" ] || [ -L "$link" ]; then exit \(Exit.changed); fi
          /bin/ln -sh -- "$helper" "$link" || exit \(Exit.failed)
        else
          [ -L "$link" ] && [ "$(/usr/bin/readlink -- "$link")" = "$expected" ] || exit \(Exit.changed)
          tmp="$dir/.clipshot-link.$$"
          if [ -e "$tmp" ] || [ -L "$tmp" ]; then exit \(Exit.failed); fi
          /bin/ln -sh -- "$helper" "$tmp" || exit \(Exit.failed)
          /bin/mv -fh -- "$tmp" "$link" || exit \(Exit.failed)
        fi
        """

    /// Returns "0", or the error number and message on two lines; never raises, so the
    /// outcome is read the same way whatever happened.
    static let appleScript = [
        "on run argv",
        "set {theScript, helperPath, linkPath, expectedTarget, promptText, asAdmin} to argv",
        "set cmd to \"/bin/sh -c \" & quoted form of theScript & \" clipshot \" & quoted form of helperPath"
            + " & \" \" & quoted form of linkPath & \" \" & quoted form of expectedTarget",
        "try",
        "if asAdmin is \"1\" then",
        "do shell script cmd with prompt promptText with administrator privileges",
        "else",
        "do shell script cmd",
        "end if",
        "return \"0\"",
        "on error errMsg number errNum",
        "return (errNum as text) & linefeed & errMsg",
        "end try",
        "end run",
    ]

    func link(
        helper: URL, at link: URL, replacing: String?, asAdministrator: Bool, prompt: String
    ) async -> CommandLineLinkResult {
        let arguments = Self.appleScript.flatMap { ["-e", $0] }
            + [Self.shellScript, helper.path, link.path, replacing ?? "", prompt, asAdministrator ? "1" : "0"]
        let (status, output, errors) = await Self.run("/usr/bin/osascript", arguments)
        guard status == 0 else { return .failed(errors.isEmpty ? "osascript exited with \(status)" : errors) }
        return Self.result(of: output)
    }

    /// The handler's answer: "0", or "<number>\n<message>".
    static func result(of output: String) -> CommandLineLinkResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "0" { return .linked }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let message = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch Int(lines.first ?? "") {
        case -128: return .cancelled
        case Exit.noTool: return .noTool
        case Exit.changed: return .changed
        case let code?: return .failed(message.isEmpty ? "error \(code)" : message)
        case nil: return .failed(text)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let out = output.fileHandleForReading, err = errors.fileHandleForReading
            process.terminationHandler = { process in
                let text = String(decoding: out.readDataToEndOfFile(), as: UTF8.self)
                let message = String(decoding: err.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus, text, message))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, "", error.localizedDescription))
            }
        }
    }
}

/// The Command line section's state: the status, and how the last Install or Fix went.
@MainActor
@Observable
final class CommandLineSetup {
    enum Activity: Equatable {
        case idle
        case working
        /// A link attempt that did not link, said under the row until the next one.
        case ended(CommandLineLinkResult)
    }

    let locations: CommandLineLocations
    private(set) var status: CommandLineStatus
    var activity: Activity = .idle
    /// Copy Command was clicked: the footer says what to do with it.
    var commandCopied = false
    private let linker: any CommandLineLinking

    init(locations: CommandLineLocations = .live(), linker: any CommandLineLinking = ScriptLinker()) {
        self.locations = locations
        self.linker = linker
        status = .detect(locations)
    }

    func refresh() {
        status = .detect(locations)
    }

    /// The pane went away: a stale outcome does not greet the next visit.
    func reset() {
        if activity != .working { activity = .idle }
        commandCopied = false
        refresh()
    }

    /// Install for `notInstalled`, Fix for `stale` (after the user confirmed). The password
    /// prompt only when the folder, or the nearest one that exists, is not writable.
    func install() async {
        guard activity != .working, let action = status.action(installTarget: locations.installTarget) else { return }
        activity = .working
        let folder = action.link.deletingLastPathComponent()
        let result = await linker.link(
            helper: locations.helper, at: action.link, replacing: action.replacing,
            asAdministrator: Self.needsAdministrator(folder),
            prompt: String(localized: Copy.CommandLine.prompt(locations.display(folder))))
        refresh()
        activity = result == .linked ? .idle : .ended(result)
    }

    func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(locations.manualCommand, forType: .string)
        commandCopied = true
    }

    /// Whether making a link in `folder` needs the password: the folder, or the nearest one
    /// above it that exists (mkdir -p creates the rest), is not writable by this user.
    nonisolated static func needsAdministrator(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        var current = folder.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return !fileManager.isWritableFile(atPath: current.path)
    }
}
