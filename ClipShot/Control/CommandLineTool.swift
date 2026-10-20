import AppKit
import Foundation

// `clipshot`, the command line tool (Addendum C). Its logic lives here, compiled into the app
// as well as into the tool, so the test suite runs it in process; `ClipShotCLI/main.swift`
// only hands it the arguments and prints what it returns.

/// Exit codes.
enum CLIExit: Int32 {
    case ok = 0
    case error = 1
    case usage = 2
    /// The command needs the running app and it is not running.
    case notRunning = 3
}

enum CLICommand: Equatable, Sendable {
    case status
    case latest(count: Int)
    /// nil: the latest screenshot.
    case copy(path: String?)
    case pause
    case resume
    case clean(dryRun: Bool)
    /// nil: the whole tool; else one command's help.
    case help(String?)
    case version
}

struct CLIInvocation: Equatable, Sendable {
    var command: CLICommand
    var json = false
}

/// A command line that is not a valid invocation: exit 2, with the help of `topic`.
struct CLIUsageError: Error, Equatable {
    let message: String
    /// The command whose help follows the message; nil for the tool's.
    let topic: String?
}

enum CLIParser {
    static let commands = ["status", "latest", "copy", "pause", "resume", "clean"]
    /// The most `latest -n` gives: what Get Recent Screenshots gives.
    static let maxCount = RecentScreenshots.maxRequested

    static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        guard let first = arguments.first else { return .success(CLIInvocation(command: .status)) }
        switch first {
        case "-h", "--help", "help":
            guard arguments.count <= 2 else {
                return .failure(CLIUsageError(message: "help takes one command at most", topic: nil))
            }
            guard let topic = arguments.dropFirst().first else { return .success(CLIInvocation(command: .help(nil))) }
            guard commands.contains(topic) else {
                return .failure(CLIUsageError(message: "unknown command \"\(topic)\"", topic: nil))
            }
            return .success(CLIInvocation(command: .help(topic)))
        case "-v", "-V", "--version", "version":
            guard arguments.count == 1 else {
                return .failure(CLIUsageError(message: "\(first) takes no arguments", topic: nil))
            }
            return .success(CLIInvocation(command: .version))
        default:
            break
        }
        // `clipshot --json` is `clipshot status --json`.
        let (name, rest) = first.hasPrefix("-") ? ("status", arguments[...]) : (first, arguments.dropFirst())
        guard commands.contains(name) else {
            return .failure(CLIUsageError(message: "unknown command \"\(name)\"", topic: nil))
        }
        return parse(name, Array(rest))
    }

    private static func parse(_ name: String, _ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        var json = false
        var count = 1
        var dryRun = false
        var latest = false
        var path: String?
        var flagsEnded = false
        var index = 0
        func usage(_ message: String) -> Result<CLIInvocation, CLIUsageError> {
            .failure(CLIUsageError(message: message, topic: name))
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if !flagsEnded, argument.hasPrefix("-"), argument != "-" {
                switch (name, argument) {
                case (_, "-h"), (_, "--help"):
                    return .success(CLIInvocation(command: .help(name)))
                case (_, "--json"):
                    json = true
                case (_, "--") where name == "copy":
                    flagsEnded = true
                case ("latest", "-n"), ("latest", "--count"):
                    guard index < arguments.count else { return usage("\(argument) needs a number from 1 to \(maxCount)") }
                    guard let n = Int(arguments[index]), (1...maxCount).contains(n) else {
                        return usage("\(argument) needs a number from 1 to \(maxCount), not \"\(arguments[index])\"")
                    }
                    count = n
                    index += 1
                case ("copy", "--latest"):
                    latest = true
                case ("clean", "--dry-run"):
                    dryRun = true
                default:
                    return usage("unknown flag \(argument) for `\(name)`; valid: \(flags[name, default: "--json"])")
                }
            } else {
                guard name == "copy", path == nil else {
                    return usage("unexpected argument \"\(argument)\" for `\(name)`")
                }
                path = argument
            }
        }
        if latest, path != nil { return usage("give a path or --latest, not both") }
        if path?.isEmpty == true { return usage("the path is empty") }
        let command: CLICommand = switch name {
        case "latest": .latest(count: count)
        case "copy": .copy(path: path)
        case "pause": .pause
        case "resume": .resume
        case "clean": .clean(dryRun: dryRun)
        default: .status
        }
        return .success(CLIInvocation(command: command, json: json))
    }

    private static let flags = [
        "status": "--json",
        "latest": "-n N, --json",
        "copy": "PATH, --latest, --json",
        "pause": "--json",
        "resume": "--json",
        "clean": "--dry-run, --json",
    ]
}

/// What `clipshot` prints and how it exits.
struct CLIOutput: Equatable, Sendable {
    var stdout = ""
    var stderr = ""
    var exit: CLIExit = .ok
}

/// What `clipshot` reads itself, read-only, while the app is not running: the ledger, the
/// screenshot folder the macOS settings name, and the app's own settings.
struct CLIOfflineSources: Sendable {
    var ledgerURL: URL
    /// The folder the app would watch: the configured one, ~/Desktop while it is missing.
    var folder: @Sendable () -> URL
    /// The app's settings, read only (`Preferences` writes only when a value is set).
    var preferences: @MainActor @Sendable () -> Preferences
    /// Why `policy`, while on, would not run on the configured folder now, as the app's
    /// status says (`RetentionPolicy.refusal`).
    var retentionRefusal: @Sendable (RetentionPolicy) -> Refusal?
    /// Whether ClipShot runs, when its socket does not answer: then the socket, not the app,
    /// is what is missing.
    var appRunning: @Sendable () -> Bool
    /// ClipShot was launched within the last `recentLaunch`: its socket may not be bound
    /// yet, so the tool waits for it a little (`CommandLineTool.startupGrace`).
    var appLaunchedRecently: @Sendable () -> Bool = { false }

    /// How recent a launch still counts as starting up.
    static let recentLaunch: TimeInterval = 10

    /// The app's own files and settings. Nothing is written: the ledger is read, the
    /// screenshot settings are read, and the app's defaults domain is read.
    /// `findsRunningApp` false: the socket is not the app's (`CLIPSHOT_SUPPORT_DIR`), so a
    /// running ClipShot says nothing about it.
    static func live(
        supportDirectory: URL, appDefaultsDomain: String = "sk.moravcik.ClipShot", findsRunningApp: Bool = true
    ) -> CLIOfflineSources {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = supportDirectory
        // Read only: `folder()` reads the macOS screenshot settings; nothing here writes them.
        let settings = CaptureSettings(
            prefs: SystemScreencapturePreferences(), home: home,
            backup: PrefsBackup(fileURL: support.appendingPathComponent("prefs-backup.plist")),
            log: CommandLineTool.quietLog)
        return CLIOfflineSources(
            ledgerURL: support.appendingPathComponent("ledger.json"),
            folder: {
                let configured = settings.folder()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: configured.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { return home.appendingPathComponent("Desktop", isDirectory: true) }
                return configured
            },
            preferences: {
                Preferences(store: UserDefaults(suiteName: appDefaultsDomain) ?? UserDefaults.standard)
            },
            retentionRefusal: { policy in
                policy.refusal(folder: settings.folder(), home: home, hasTrash: FolderGuard.systemTrashLookup)
            },
            appRunning: {
                findsRunningApp && !NSRunningApplication.runningApplications(withBundleIdentifier: appDefaultsDomain).isEmpty
            },
            appLaunchedRecently: {
                guard findsRunningApp else { return false }
                return NSRunningApplication.runningApplications(withBundleIdentifier: appDefaultsDomain).contains {
                    guard let launched = $0.launchDate else { return false }
                    return Date().timeIntervalSince(launched) < recentLaunch
                }
            })
    }
}

@MainActor
struct CommandLineTool {
    let version: String
    let socket: URL
    let workingDirectory: URL
    let offline: CLIOfflineSources
    /// How long `clean` may take: a run moves up to 500 files to the Trash. Longer than the
    /// app's own deadline (`ControlServer.Limits`), so its "timed out" answer arrives.
    var cleanTimeout: Duration = .seconds(180)
    var timeout: Duration = .seconds(30)
    /// How long the tool waits for the socket of a ClipShot launched just now: longer than
    /// the app's start, its retry after "in use" (`ControlHost.retryDelay`) and the bind.
    var startupGrace: Duration = .seconds(3)
    /// How often it tries meanwhile.
    var startupRetryInterval: Duration = .milliseconds(100)

    /// The tool never writes the app's log; a read that logs goes nowhere.
    nonisolated static let quietLog = Log(fileURL: URL(fileURLWithPath: "/dev/null"))

    func run(_ arguments: [String]) async -> CLIOutput {
        let invocation: CLIInvocation
        switch CLIParser.parse(arguments) {
        case .failure(let usage):
            // An agent that asked for JSON reads the error as JSON too.
            let json = arguments.contains("--json")
                ? CLIRender.json(["error": ["code": "usage", "message": usage.message]]) : ""
            return CLIOutput(
                stdout: json, stderr: "error: \(usage.message)\n\n" + CLIHelp.text(usage.topic), exit: .usage)
        case .success(let parsed):
            invocation = parsed
        }
        var out = CLIOutput()
        switch invocation.command {
        case .help(let topic):
            out.stdout = CLIHelp.text(topic)
        case .version:
            out.stdout = "\(version)\n"
        case .status:
            await status(invocation, &out)
        case .latest(let count):
            await latest(count, invocation, &out)
        case .copy(let path):
            let absolute = path.map { URL(fileURLWithPath: $0, relativeTo: workingDirectory).standardizedFileURL.path }
            await ask(ControlRequest(command: .copy, path: absolute), invocation, &out) { response in
                guard let copied = response.copied else { return nil }
                return invocation.json ? CLIRender.json(["copied": copied]) : "copied: \(copied)\n"
            }
        case .pause, .resume:
            let on = invocation.command == .resume
            await ask(ControlRequest(command: on ? .resume : .pause), invocation, &out) { response in
                guard let copying = response.copying else { return nil }
                return invocation.json ? CLIRender.json(copying) : CLIRender.copying(copying)
            }
        case .clean(let dryRun):
            await ask(ControlRequest(command: .clean, dryRun: dryRun), invocation, &out, timeout: cleanTimeout) { response in
                guard let cleanup = response.cleanup else { return nil }
                return invocation.json ? CLIRender.json(cleanup) : CLIRender.cleanup(cleanup)
            }
        }
        return out
    }

    // MARK: Commands

    private func status(_ invocation: CLIInvocation, _ out: inout CLIOutput) async {
        switch await send(ControlRequest(command: .status), timeout: timeout) {
        case .success(let response):
            if let failure = response.error { return fail(failure.code.rawValue, failure.message, .error, invocation, &out) }
            guard let status = response.status else { return clientFailure(.badResponse, invocation, &out) }
            out.stdout = invocation.json ? CLIRender.json(status) : CLIRender.status(status)
        case .failure(.notRunning) where !offline.appRunning():
            let status = await offlineStatus()
            out.stdout = invocation.json ? CLIRender.json(status) : CLIRender.status(status)
        case .failure(let failure):
            clientFailure(failure, invocation, &out)
        }
    }

    private func latest(_ count: Int, _ invocation: CLIInvocation, _ out: inout CLIOutput) async {
        let screenshots: [ControlScreenshot]
        switch await send(ControlRequest(command: .latest, count: count), timeout: timeout) {
        case .success(let response):
            if let failure = response.error { return fail(failure.code.rawValue, failure.message, .error, invocation, &out) }
            guard let list = response.screenshots else { return clientFailure(.badResponse, invocation, &out) }
            screenshots = list
        case .failure(.notRunning):
            switch await offlineLatest(count) {
            case .failure(let failure): return fail(failure.code.rawValue, failure.message, .error, invocation, &out)
            case .success(let list): screenshots = list
            }
        case .failure(let failure):
            return clientFailure(failure, invocation, &out)
        }
        out.stdout = invocation.json
            ? CLIRender.json(["screenshots": screenshots])
            : screenshots.map { $0.path + "\n" }.joined()
    }

    /// Sends a command only the running app can carry out and renders its answer.
    private func ask(
        _ request: ControlRequest, _ invocation: CLIInvocation, _ out: inout CLIOutput, timeout: Duration? = nil,
        render: (ControlResponse) -> String?
    ) async {
        switch await send(request, timeout: timeout ?? self.timeout) {
        case .success(let response):
            if let failure = response.error { return fail(failure.code.rawValue, failure.message, .error, invocation, &out) }
            guard let text = render(response) else { return clientFailure(.badResponse, invocation, &out) }
            out.stdout = text
        case .failure(let failure):
            clientFailure(failure, invocation, &out)
        }
    }

    /// The socket is read and written off the main actor: in tests the app's model answers
    /// on it.
    ///
    /// Nobody answering while ClipShot runs and was launched just now is a socket not bound
    /// yet: the tool tries again every `startupRetryInterval` until `startupGrace` has passed.
    /// Not running at all, or running for longer, is answered at once.
    private func send(_ request: ControlRequest, timeout: Duration) async -> Result<ControlResponse, ControlClient.Failure> {
        let socket = socket
        let deadline = ContinuousClock.now + startupGrace
        while true {
            let result = await Task.detached { ControlClient.send(request, to: socket, timeout: timeout) }.value
            guard case .failure(.notRunning) = result, ContinuousClock.now < deadline,
                  offline.appRunning(), offline.appLaunchedRecently()
            else { return result }
            try? await Task.sleep(for: startupRetryInterval)
        }
    }

    // MARK: Without the app

    /// Status read from the files, while ClipShot is not running: nothing copies.
    func offlineStatus() async -> ControlStatus {
        let preferences = offline.preferences()
        let ready = preferences.tourCompleted
        let policy = preferences.retention
        let refusal = policy.enabled ? await Task.detached { [offline] in offline.retentionRefusal(policy) }.value : nil
        let retention = ControlStatus.Retention(
            enabled: policy.enabled, days: policy.days, refusal: refusal?.controlName)
        let folder = ready ? await Task.detached { [offline] in offline.folder() }.value : nil
        let latest = ready ? (try? await offlineLatest(1).get())?.first?.path : nil
        return ControlStatus(
            running: false, appVersion: nil, copying: false, pausedBy: .notRunning, folder: folder?.path,
            retention: retention, latest: latest)
    }

    /// `latest` from the ledger and the folder, read-only, with the app's selection rules
    /// (`RecentScreenshots.select`, then `FileTrust`). Not before the welcome tour, as the
    /// app refuses then too.
    func offlineLatest(_ count: Int) async -> Result<[ControlScreenshot], ControlFailure> {
        guard offline.preferences().tourCompleted else {
            return .failure(ControlFailure(code: .notSetUp, message: ShortcutErrorText.notSetUp))
        }
        let ledger = ScreenshotLedger(fileURL: offline.ledgerURL, log: Self.quietLog)
        let entries = await ledger.entries()
        let offline = offline
        let files = await Task.detached {
            let candidates = RecentScreenshots.select(
                lastCopied: nil, ledger: entries, folder: offline.folder(), count: CLIParser.maxCount)
            return ControlScreenshots.trusted(candidates, count: count)
        }.value
        guard !files.isEmpty else {
            return .failure(ControlFailure(code: .noScreenshots, message: ShortcutErrorText.noScreenshots))
        }
        return .success(files.map(ControlScreenshots.info))
    }

    // MARK: Failures

    private func clientFailure(_ failure: ControlClient.Failure, _ invocation: CLIInvocation, _ out: inout CLIOutput) {
        switch failure {
        case .notRunning where offline.appRunning():
            fail("socketUnavailable",
                 "ClipShot is running, but its control socket is not available, so clipshot cannot reach it. "
                    + "See ~/Library/Logs/clipshot.log, then quit ClipShot and open it again.",
                 .error, invocation, &out)
        case .notRunning:
            fail("notRunning", "ClipShot is not running. Start it with: open -a ClipShot", .notRunning, invocation, &out)
        case .unsafeSocket:
            fail("unsafeSocket",
                 "\(socket.path) is not ClipShot's socket, so clipshot does not use it. "
                    + "Quit ClipShot, move that file to the Trash, and open ClipShot again.",
                 .error, invocation, &out)
        case .timedOut:
            fail("timedOut", "ClipShot did not answer in time.", .error, invocation, &out)
        case .badResponse:
            fail("badResponse", "ClipShot's answer could not be read.", .error, invocation, &out)
        case .version(let app):
            fail("version",
                 "ClipShot speaks protocol \(app), this clipshot speaks \(ControlProtocol.version). "
                    + "Use the clipshot that comes with ClipShot.app (ClipShot.app/Contents/Helpers/clipshot).",
                 .error, invocation, &out)
        case .system(let error):
            fail("system", "Could not reach ClipShot: \(String(cString: strerror(error))).", .error, invocation, &out)
        }
    }

    /// Errors go to stderr, so `$(clipshot latest)` never takes one for a path; with
    /// `--json` the error object goes to stdout as well, for a caller that parses it.
    private func fail(_ code: String, _ message: String, _ exit: CLIExit, _ invocation: CLIInvocation, _ out: inout CLIOutput) {
        out.exit = exit
        out.stderr = "error: \(message)\n"
        if invocation.json { out.stdout = CLIRender.json(["error": ["code": code, "message": message]]) }
    }
}

/// The English text of the Shortcuts' refusals, for the terminal: the same words as the
/// Shortcuts actions say (their keys are the English text).
enum ShortcutErrorText {
    static let notSetUp = "Finish setting up ClipShot first: open it from the menu bar."
    static let noScreenshots = "No screenshots yet. ClipShot finds the ones taken while it runs."
}

enum CLIRender {
    static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? ControlProtocol.encoder().encode(value) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func status(_ s: ControlStatus) -> String {
        var lines: [String] = []
        lines.append("app: " + (s.running ? "ClipShot \(s.appVersion ?? "")" : "not running (start it: open -a ClipShot)"))
        let blocking = (s.attention ?? []).filter { Attention.blockingKinds.contains($0) }
        let copying = switch s.pausedBy {
        case nil where s.copying: "on"
        case nil where !blocking.isEmpty:
            "needs attention (" + blocking.map(Attention.describe(kind:)).joined(separator: "; ") + ")"
        case nil: "paused"
        case .manual?: "paused"
        case .focus?: "paused while a Focus is on"
        case .setup?: "off until ClipShot is set up: open it from the menu bar"
        case .notRunning?: "off while ClipShot is not running"
        }
        lines.append("copying: \(copying)")
        lines.append("folder: \(s.folder ?? "not known yet")")
        var cleanup = s.retention.enabled ? "after \(s.retention.days) \(s.retention.days == 1 ? "day" : "days")" : "off"
        if s.retention.enabled, let refusal = s.retention.refusal { cleanup += ", " + refusalText(refusal) }
        lines.append("cleanup: \(cleanup)")
        lines.append("latest: \(s.latest ?? "none")")
        if let attention = s.attention, !attention.isEmpty {
            lines.append("attention: " + attention.map(Attention.describe(kind:)).joined(separator: "; "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func refusalText(_ refusal: String) -> String {
        switch refusal {
        case "notConfirmed": "paused until you check what it would move in ClipShot's settings"
        case "systemOrBroad": "off for this folder: a system or home-level folder"
        case "noTrash": "off for this folder: its volume has no Trash"
        case "folderMissing": "the screenshot folder does not exist"
        default: "off for this folder"
        }
    }

    static func copying(_ c: ControlCopying) -> String {
        if c.tookOverFocusPause == true { return "copying paused (stays paused after the Focus ends)\n" }
        return switch (c.copying, c.changed) {
        case (true, true): "copying resumed\n"
        case (true, false): "copying was already on\n"
        case (false, true): "copying paused\n"
        case (false, false): "copying was already paused\n"
        }
    }

    static func cleanup(_ c: ControlCleanup) -> String {
        let what = "\(c.count) \(c.count == 1 ? "screenshot" : "screenshots") (\(bytes(c.bytes)))"
        guard c.dryRun else {
            return c.count == 0 ? "nothing to clean up\n" : "moved \(what) to the Trash\n"
        }
        guard c.count > 0 else { return "nothing to clean up\n" }
        return "would move \(what) to the Trash:\n" + c.files.map { $0 + "\n" }.joined()
    }

    /// Decimal units, as Finder shows sizes: 1.2 MB.
    static func bytes(_ count: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        if unit == 0 { return count == 1 ? "1 byte" : "\(count) bytes" }
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}

enum CLIHelp {
    static func text(_ topic: String?) -> String {
        switch topic {
        case "status"?:
            return """
                usage: clipshot [status] [--json]

                Whether copying is on or paused (and why: by you, or a Focus), the screenshot folder,
                cleanup, and the latest screenshot. Works while ClipShot is not running too.

                examples:
                  clipshot
                  clipshot status --json

                """
        case "latest"?:
            return """
                usage: clipshot latest [-n N] [--json]

                The paths of the newest screenshots ClipShot saw being taken, newest first, one per
                line. N is 1 to \(CLIParser.maxCount), default 1. Reads only; works while ClipShot is not running.

                examples:
                  open "$(clipshot latest)"
                  clipshot latest -n 3
                  clipshot latest --json

                """
        case "copy"?:
            return """
                usage: clipshot copy [PATH | --latest] [--json]

                Copies a screenshot to the clipboard through ClipShot, as its Copy button does, also
                while copying is paused. PATH must be a screenshot ClipShot saw being taken, directly in
                the screenshot folder; any other file is refused. Without PATH, the latest screenshot is
                copied. Needs ClipShot running.

                examples:
                  clipshot copy
                  clipshot copy ~/Desktop/Screenshot.png

                """
        case "pause"?, "resume"?:
            return """
                usage: clipshot pause [--json]
                       clipshot resume [--json]

                Switches copying off or on, as the switch in ClipShot's menu does. A pause by hand is
                never undone by a Focus. Needs ClipShot running.

                """
        case "clean"?:
            return """
                usage: clipshot clean [--dry-run] [--json]

                Moves screenshots past the cleanup age to the Trash now, with all of ClipShot's
                checks: only screenshots it saw being taken, only in a confirmed folder, at most 500
                at a time. Cleanup must be on in ClipShot's settings. --dry-run lists what would
                move and moves nothing. Needs ClipShot running.

                examples:
                  clipshot clean --dry-run
                  clipshot clean

                """
        default:
            return """
                clipshot: ClipShot from the terminal, for scripts and coding agents.

                usage:
                  clipshot [status] [--json]            copying on or paused, folder, cleanup, latest
                  clipshot latest [-n N] [--json]       newest screenshot paths, newest first (N 1-\(CLIParser.maxCount))
                  clipshot copy [PATH | --latest] [--json]
                                                        copy a screenshot to the clipboard
                  clipshot pause | resume [--json]      switch copying off or on
                  clipshot clean [--dry-run] [--json]   move old screenshots to the Trash now
                  clipshot help [COMMAND] | --version

                copy, pause, resume and clean need ClipShot running (open -a ClipShot).
                exit codes: 0 ok, 1 error, 2 usage, 3 ClipShot is not running

                examples:
                  open "$(clipshot latest)"
                  clipshot latest -n 3 --json
                  clipshot clean --dry-run

                """
        }
    }
}
