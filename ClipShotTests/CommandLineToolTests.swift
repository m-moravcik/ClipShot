import Foundation
import Testing
@testable import ClipShot

/// `clipshot` (Addendum C), run in process: its arguments, its output and exit codes, and its
/// commands carried out by the app's model over a real control socket, on the same paths as
/// the Shortcuts actions.
@MainActor
struct CommandLineToolTests {
    /// The path as the app lists it: the folder resolved (/var is /private/var), the name kept.
    private func canon(_ url: URL) -> String { FolderGuard.canonicalPath(url) }

    // MARK: Arguments

    @Test func argumentsParse() {
        func parsed(_ arguments: [String]) -> CLIInvocation? { try? CLIParser.parse(arguments).get() }
        #expect(parsed([]) == CLIInvocation(command: .status))
        #expect(parsed(["status"]) == CLIInvocation(command: .status))
        #expect(parsed(["--json"]) == CLIInvocation(command: .status, json: true))
        #expect(parsed(["status", "--json"]) == CLIInvocation(command: .status, json: true))
        #expect(parsed(["latest"]) == CLIInvocation(command: .latest(count: 1)))
        #expect(parsed(["latest", "-n", "3", "--json"]) == CLIInvocation(command: .latest(count: 3), json: true))
        #expect(parsed(["latest", "-n", "10"]) == CLIInvocation(command: .latest(count: 10)))
        #expect(parsed(["copy"]) == CLIInvocation(command: .copy(path: nil)))
        #expect(parsed(["copy", "--latest"]) == CLIInvocation(command: .copy(path: nil)))
        #expect(parsed(["copy", "shot.png"]) == CLIInvocation(command: .copy(path: "shot.png")))
        #expect(parsed(["copy", "--", "-odd.png"]) == CLIInvocation(command: .copy(path: "-odd.png")))
        #expect(parsed(["pause"]) == CLIInvocation(command: .pause))
        #expect(parsed(["resume", "--json"]) == CLIInvocation(command: .resume, json: true))
        #expect(parsed(["clean"]) == CLIInvocation(command: .clean(dryRun: false)))
        #expect(parsed(["clean", "--dry-run", "--json"]) == CLIInvocation(command: .clean(dryRun: true), json: true))
        for version in ["--version", "-v", "-V", "version"] {
            #expect(parsed([version]) == CLIInvocation(command: .version))
        }
        #expect(parsed(["--help"]) == CLIInvocation(command: .help(nil)))
        #expect(parsed(["help", "clean"]) == CLIInvocation(command: .help("clean")))
        #expect(parsed(["latest", "--help"]) == CLIInvocation(command: .help("latest")))
    }

    @Test func usageErrorsNameTheProblemAndTheCommand() {
        func usage(_ arguments: [String]) -> CLIUsageError? {
            if case .failure(let error) = CLIParser.parse(arguments) { error } else { nil }
        }
        #expect(usage(["frobnicate"]) == CLIUsageError(message: "unknown command \"frobnicate\"", topic: nil))
        #expect(usage(["latest", "-n", "0"])?.topic == "latest")
        #expect(usage(["latest", "-n", "11"])?.message.contains("1 to 10") == true)
        #expect(usage(["latest", "-n"]) != nil)
        #expect(usage(["latest", "-n", "two"]) != nil)
        #expect(usage(["copy", "a.png", "b.png"])?.topic == "copy")
        #expect(usage(["copy", "a.png", "--latest"])?.message == "give a path or --latest, not both")
        #expect(usage(["pause", "--dry-run"])?.message == "unknown flag --dry-run for `pause`; valid: --json")
        #expect(usage(["clean", "--force"])?.message == "unknown flag --force for `clean`; valid: --dry-run, --json")
        #expect(usage(["status", "extra"]) != nil)
        #expect(usage(["--version", "now"]) != nil)
        #expect(usage(["help", "nope"]) != nil)
        #expect(usage(["status", "--"]) != nil, "-- only ends flags for copy")
    }

    @Test func usageExitsWithTwoAndTheCommandsHelp() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let out = await h.tool(try CT.shortDir()).run(["latest", "--bogus"])
        #expect(out.exit == .usage)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr.hasPrefix("error: unknown flag --bogus for `latest`"))
        #expect(out.stderr.contains("usage: clipshot latest"))
    }

    @Test func usageErrorsAreJSONWhenJSONWasAskedFor() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let out = await h.tool(try CT.shortDir()).run(["latest", "-n", "99", "--json"])
        #expect(out.exit == .usage)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: [String: String]])
        #expect(object["error"]?["code"] == "usage")
        #expect(object["error"]?["message"]?.contains("1 to 10") == true)
        #expect(out.stderr.contains("usage: clipshot latest"))
    }

    /// The parser and the app allow the same counts: one constant.
    @Test func latestCountsAreTheShortcutsCounts() {
        #expect(CLIParser.maxCount == AppModel.shortcutMaxCount)
        #expect(CLIParser.maxCount == RecentScreenshots.maxRequested)
        #expect((try? CLIParser.parse(["latest", "-n", "\(CLIParser.maxCount)"]).get()) != nil)
        #expect((try? CLIParser.parse(["latest", "-n", "\(CLIParser.maxCount + 1)"]).get()) == nil)
    }

    @Test func helpAndVersion() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let tool = h.tool(try CT.shortDir())
        #expect(await tool.run(["--version"]) == CLIOutput(stdout: "0.9.0\n"))
        let help = await tool.run(["--help"])
        #expect(help.exit == .ok && help.stderr.isEmpty)
        for command in CLIParser.commands { #expect(help.stdout.contains(command)) }
        #expect(help.stdout.contains("exit codes: 0 ok, 1 error, 2 usage, 3 ClipShot is not running"))
        for line in ["clipshot copy [PATH | --latest] [--json]", "clipshot pause | resume [--json]", "clipshot clean [--dry-run] [--json]"] {
            #expect(help.stdout.contains(line))
        }
        #expect(await tool.run(["help", "clean"]).stdout.contains("--dry-run"))
    }

    // MARK: Output shapes

    /// Every key is there, null included, whatever the state: scripts read one shape.
    @Test func jsonShapes() throws {
        func object(_ text: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let paused = ControlStatus(
            running: true, appVersion: "0.9.0", copying: false, pausedBy: .focus, folder: "/f",
            retention: ControlStatus.Retention(enabled: true, days: 7, refusal: "notConfirmed"), latest: nil)
        let status = try object(CLIRender.json(paused))
        #expect(Set(status.keys) == ["running", "appVersion", "copying", "pausedBy", "folder", "retention", "latest", "attention"])
        #expect(status["attention"] is NSNull)
        #expect(status["pausedBy"] as? String == "focus")
        #expect(status["latest"] is NSNull)
        let retention = try #require(status["retention"] as? [String: Any])
        #expect(Set(retention.keys) == ["enabled", "days", "refusal"])
        let on = try object(CLIRender.json(ControlStatus(
            running: false, appVersion: nil, copying: false, pausedBy: .notRunning, folder: nil,
            retention: ControlStatus.Retention(enabled: false, days: 30, refusal: nil), latest: nil)))
        #expect(on["appVersion"] is NSNull && on["folder"] is NSNull)
        #expect((on["retention"] as? [String: Any])?["refusal"] is NSNull)

        let shot = ControlScreenshot(path: "/f/a b.png", created: Date(timeIntervalSince1970: 1_800_000_000), size: 42)
        let latest = try object(CLIRender.json(["screenshots": [shot]]))
        let first = try #require((latest["screenshots"] as? [[String: Any]])?.first)
        #expect(first["path"] as? String == "/f/a b.png")
        #expect(first["created"] as? String == "2027-01-15T08:00:00Z")
        #expect(first["size"] as? Int == 42)

        let cleanup = try object(CLIRender.json(ControlCleanup(dryRun: true, count: 1, bytes: 5, files: ["/f/old.png"])))
        #expect(Set(cleanup.keys) == ["dryRun", "count", "bytes", "files"])
        #expect(Set(try object(CLIRender.json(ControlCopying(copying: false, changed: true))).keys) == ["copying", "changed"])
    }

    @Test func textOutput() {
        let status = ControlStatus(
            running: true, appVersion: "0.9.0", copying: false, pausedBy: .manual, folder: "/Users/me/Shots",
            retention: ControlStatus.Retention(enabled: true, days: 30, refusal: "notConfirmed"), latest: "/Users/me/Shots/a.png")
        #expect(CLIRender.status(status) == """
            app: ClipShot 0.9.0
            copying: paused
            folder: /Users/me/Shots
            cleanup: after 30 days, paused until you check what it would move in ClipShot's settings
            latest: /Users/me/Shots/a.png

            """)
        #expect(CLIRender.bytes(0) == "0 bytes")
        #expect(CLIRender.bytes(1_234_567) == "1.2 MB")
        #expect(CLIRender.cleanup(ControlCleanup(dryRun: true, count: 2, bytes: 2_000, files: ["/a", "/b"]))
            == "would move 2 screenshots (2.0 KB) to the Trash:\n/a\n/b\n")
        #expect(CLIRender.cleanup(ControlCleanup(dryRun: false, count: 0, bytes: 0, files: [])) == "nothing to clean up\n")
    }

    /// The terminal says what the Shortcuts actions say.
    @Test func refusalsUseTheShortcutsWords() {
        #expect(ShortcutErrorText.notSetUp == Copy.Shortcuts.notSetUp.key)
        #expect(ShortcutErrorText.noScreenshots == Copy.Shortcuts.noScreenshots.key)
        #expect(AppModel.controlResponse(.retentionOff).error == ControlFailure(code: .retentionOff, message: Copy.Shortcuts.retentionOff.key))
        #expect(AppModel.controlResponse(.retentionRefused(.noTrash)).error?.message
            == Copy.Summary.offForFolder.key + ": its volume has no Trash.")
    }

    // MARK: Through the app

    @Test func statusSaysWhetherCopyingIsOnAndWhy() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let url = try RT.shot("shot.png", in: h.folder, age: 60, now: RT.now())
        await h.ledger.record(RT.file(url))
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)

        var out = await tool.run(["status", "--json"])
        #expect(out.exit == .ok)
        var status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(out.stdout.utf8))
        #expect(status == ControlStatus(
            running: true, appVersion: "0.9.0", copying: true, pausedBy: nil, folder: h.folder.path,
            retention: ControlStatus.Retention(enabled: false, days: 30, refusal: nil), latest: canon(url),
            attention: []))

        h.preferences.copyEnabled = false
        status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(!status.copying && status.pausedBy == .manual)

        h.preferences.copyEnabled = true
        h.model.focusChanged(pausing: true)
        out = await tool.run([])
        #expect(out.stdout.contains("copying: paused while a Focus is on"))
    }

    @Test func pauseAndResumeAreTheSwitch() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        #expect(await tool.run(["pause"]) == CLIOutput(stdout: "copying paused\n"))
        #expect(!h.preferences.copyEnabled)
        #expect(await eventually { await h.model.flashMoment == .pause ? h.model.flashPhase > 0 : false }, "Peg's pause")
        #expect(await eventually { await !h.model.copyEnabledInPipeline })
        #expect(await tool.run(["pause"]) == CLIOutput(stdout: "copying was already paused\n"), "idempotent, exit 0")
        #expect(await tool.run(["resume", "--json"]).stdout == #"{"changed":true,"copying":true}"# + "\n")
        #expect(h.preferences.copyEnabled)
    }

    /// A Focus paused copying; `clipshot pause` makes the pause the user's, so it outlives the
    /// Focus: a change, and said.
    @Test func pauseDuringAFocusPauseTakesItOver() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.focusChanged(pausing: true)
        #expect(h.model.pausedByFocus)
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        #expect(await tool.run(["pause"]).stdout == "copying paused (stays paused after the Focus ends)\n")
        #expect(!h.preferences.copyEnabled && h.preferences.focusPause == FocusPause(focusOn: true, pausedCopying: false))
        let json = await tool.run(["pause", "--json"])
        #expect(json.stdout == #"{"changed":false,"copying":false}"# + "\n", "now nothing changes")
        h.model.focusChanged(pausing: false, immediately: true)
        #expect(!h.preferences.copyEnabled, "the Focus's end does not resume a pause by hand")
    }

    /// A Focus paused copying; `clipshot resume` is a resume by hand and wins until the Focus
    /// changes, as the popover's switch does.
    @Test func resumeDuringAFocusIsAResumeByHand() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        h.model.focusChanged(pausing: true)
        #expect(h.model.pausedByFocus)
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        #expect(await h.tool(dir).run(["resume"]).stdout == "copying resumed\n")
        #expect(h.preferences.copyEnabled && h.preferences.focusPause == FocusPause(focusOn: true, pausedCopying: false))
    }

    @Test func latestListsWhatThePopoverWouldNewestFirst() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        var urls: [URL] = []
        for (name, age) in [("a.png", 300.0), ("b.png", 200), ("c.png", 100)] {
            let url = try RT.shot(name, in: h.folder, age: age, now: now)
            await h.ledger.record(RT.file(url))
            urls.append(url)
        }
        try RT.shot("untracked.png", in: h.folder, age: 10, now: now)
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        #expect(await tool.run(["latest"]) == CLIOutput(stdout: canon(urls[2]) + "\n"))
        #expect(await tool.run(["latest", "-n", "5"]).stdout == [urls[2], urls[1], urls[0]].map { canon($0) + "\n" }.joined())
        let json = await tool.run(["latest", "-n", "2", "--json"])
        let decoded = try ControlProtocol.decoder().decode([String: [ControlScreenshot]].self, from: Data(json.stdout.utf8))
        #expect(decoded["screenshots"]?.map(\.path) == [canon(urls[2]), canon(urls[1])])
        #expect(decoded["screenshots"]?.first?.size == RT.file(urls[2]).size)
    }

    @Test func noScreenshotIsAnErrorNotAnEmptyLine() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let out = await h.tool(dir).run(["latest", "--json"])
        #expect(out.exit == .error)
        #expect(out.stderr == "error: \(Copy.Shortcuts.noScreenshots.key)\n")
        #expect(out.stdout.contains(#""code":"noScreenshots""#))
    }

    /// `clipshot copy` is the row's Copy: the same PNG, owner, total and Peg's copy moment,
    /// also while paused.
    @Test func copyTakesThePopoversCopyPath() async throws {
        let cli = try ModelHarness(), popover = try ModelHarness()
        defer { cli.tearDown(); popover.tearDown() }
        for h in [cli, popover] {
            for (name, age) in [("old.png", 200.0), ("new.png", 100)] {
                await h.ledger.record(RT.file(try RT.shot(name, in: h.folder, age: age, now: RT.now())))
            }
            h.preferences.copyEnabled = false
            #expect(await h.start())
        }
        let (server, dir) = try cli.controlServer()
        defer { server.stop() }
        let newest = cli.folder.appendingPathComponent("new.png")
        #expect(await cli.tool(dir).run(["copy"]) == CLIOutput(stdout: "copied: \(canon(newest))\n"))
        #expect(await popover.model.copyAgain(file: try #require(CaptureFile.inspect(popover.folder.appendingPathComponent("new.png")))))
        for h in [cli, popover] {
            let file = try #require(CaptureFile.inspect(h.folder.appendingPathComponent("new.png")))
            #expect(h.pasteboard.writes.count == 1)
            #expect(h.preferences.totals.copied == 1)
            #expect(h.model.isOnClipboard(file))
            #expect(h.model.flashMoment == .copied && h.model.flashPhase == 1)
            #expect(!h.preferences.copyEnabled, "still paused")
        }
        #expect(cli.pasteboard.writes == popover.pasteboard.writes)

        // A path, relative to the working directory, of a file in the folder.
        let old = cli.folder.appendingPathComponent("old.png")
        let relative = await cli.tool(dir, workingDirectory: cli.folder).run(["copy", "../Shots/./old.png"])
        #expect(relative == CLIOutput(stdout: "copied: \(old.path)\n"))
        #expect(cli.pasteboard.writes.count == 2)
    }

    @Test func copyRefusesAnythingButATrustedFileInTheFolder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        let outside = try RT.shot("outside.png", in: h.home, age: 10, now: RT.now())
        let sub = h.folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = try RT.shot("nested.png", in: sub, age: 10, now: RT.now())
        let link = h.folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let missing = await tool.run(["copy", h.folder.appendingPathComponent("typo.png").path])
        #expect(missing.exit == .error && missing.stderr.contains("No such file: "))
        let text = h.folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        // Images directly in the folder that ClipShot never saw being taken: a download with
        // no marker, a PDF, and even a marked screenshot that is not in the ledger.
        let download = try RT.shot("download.png", in: h.folder, age: 10, now: RT.now(), marker: .none, quarantine: true)
        let pdf = try Fixtures.write(named: "contract.pdf", contents: RT.png, in: h.folder, marker: .none)
        // Old enough not to be copied (and so tracked) when it appears while watching.
        let untracked = try RT.shot("untracked.png", in: h.folder, age: 120, now: RT.now())
        for url in [download, pdf, untracked] {
            let out = await tool.run(["copy", url.path])
            #expect(out.exit == .error)
            #expect(out.stderr == "error: \(url.lastPathComponent) is not a screenshot ClipShot saw being taken, so clipshot does not copy it.\n")
        }
        let cases: [(URL, String)] = [
            (outside, "notInFolder"), (nested, "notInFolder"), (link, "refusedFile"), (text, "refusedFile"),
            (h.folder.appendingPathComponent("missing.png"), "refusedFile"), (download, "refusedFile"),
            (pdf, "refusedFile"), (untracked, "refusedFile"),
        ]
        for (url, code) in cases {
            let out = await tool.run(["copy", url.path, "--json"])
            #expect(out.exit == .error, "\(url.lastPathComponent)")
            #expect(out.stdout.contains(#""code":"\#(code)""#), "\(url.lastPathComponent): \(out.stdout)")
            #expect(out.stderr.hasPrefix("error: "))
        }
        #expect(h.pasteboard.writes.isEmpty)
        #expect(h.preferences.totals.copied == 0)
    }

    /// The probe of the final review: the socket request itself, for an unmarked image
    /// directly in the folder, is refused and leaves the clipboard alone.
    @Test func handleControlRefusesAnUntrackedImageInTheFolder() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let download = try RT.shot("download.png", in: h.folder, age: 10, now: RT.now(), marker: .none)
        let response = await h.model.handleControl(ControlRequest(command: .copy, path: download.path), appVersion: "0.9.0")
        #expect(response.error?.code == .refusedFile)
        #expect(response.copied == nil)
        #expect(h.pasteboard.writes.isEmpty && h.preferences.totals.copied == 0)
    }

    /// The last copy counts as tracked even when its ledger entry is gone, as the popover
    /// still lists it.
    @Test func copyPathTakesTheLastCopyToo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let fresh = try h.shoot("fresh.png")
        #expect(await eventually { await h.model.lastCopied != nil })
        await h.model.ledgerSettled()
        let file = try #require(CaptureFile.inspect(fresh))
        await h.ledger.remove(path: FolderGuard.canonicalPath(fresh), resourceID: file.resourceID)
        let out = await h.tool(dir).run(["copy", fresh.path])
        #expect(out == CLIOutput(stdout: "copied: \(fresh.path)\n"))
    }

    /// The other copy paths are ledger-bound already: Copy Latest Screenshot and the
    /// popover's list never offer an image ClipShot did not see being taken, however new.
    @Test func shortcutsAndThePopoverOfferOnlyTrackedScreenshots() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        await h.ledger.record(RT.file(try RT.shot("shot.png", in: h.folder, age: 100, now: now)))
        try RT.shot("download.png", in: h.folder, age: 5, now: now, marker: .none, quarantine: true)
        try RT.shot("untracked.png", in: h.folder, age: 5, now: now)
        #expect(await h.start())
        #expect(try await h.model.shortcutCopyLatest().url.lastPathComponent == "shot.png")
        #expect(try await h.model.shortcutScreenshots(count: 10).files.map(\.name) == ["shot.png"])
        h.model.refreshRecent()
        #expect(await eventually { await h.model.recentSettled })
        #expect(h.model.recent.map(\.url.lastPathComponent) == ["shot.png"])
    }

    /// "Latest" is one file on every path: a newest screenshot `FileTrust` refuses (too
    /// large) is skipped by `latest` and by `copy` alike.
    @Test func latestAndCopyAgreeOnARefusedNewest() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        let older = try RT.shot("older.png", in: h.folder, age: 200, now: now)
        let huge = try RT.shot("huge.png", in: h.folder, age: 100, now: now)
        for url in [older, huge] { await h.ledger.record(RT.file(url)) }
        // Sparse: past FileTrust's 256 MB without using the disk; the same file, still marked.
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 300 * 1_024 * 1_024)
        try handle.close()
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        #expect(await tool.run(["latest"]).stdout == canon(older) + "\n")
        #expect(await tool.run(["copy"]) == CLIOutput(stdout: "copied: \(canon(older))\n"))
        #expect(h.pasteboard.writes.count == 1)
    }

    /// `latest` skips a file `FileTrust` refuses for the next newest, as Get Latest does.
    @Test func latestSkipsWhatFileTrustRefuses() throws {
        let dir = try Fixtures.makeDir()
        let files = try ["new.png", "old.png"].map { RT.file(try RT.shot($0, in: dir, age: 10, now: RT.now())) }
        #expect(ControlScreenshots.trusted(files, count: 1).map(\.url.lastPathComponent) == ["new.png"])
        let small = FileTrust.Policy(maxBytes: 4)
        #expect(ControlScreenshots.trusted(files, count: 2, policy: small).isEmpty)
        let otherOwner = FileTrust.Policy(owner: getuid() + 1)
        #expect(ControlScreenshots.trusted(files, count: 2, policy: otherOwner).isEmpty)
        // A file gone since it was listed is skipped too.
        try FileManager.default.moveItem(at: files[0].url, to: dir.appendingPathComponent("moved.png"))
        #expect(ControlScreenshots.trusted(files, count: 1).map(\.url.lastPathComponent) == ["old.png"])
    }

    @Test func cleanIsRetentionsOwnRunAndItsDryRunListsWhatWouldGo() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        var old: [URL] = []
        for (name, age) in [("old 1.png", 40 * RT.day), ("old 2.png", 35 * RT.day), ("recent.png", 2 * RT.day)] {
            let url = try RT.shot(name, in: h.folder, age: age, now: now)
            await h.ledger.record(RT.file(url))
            if age > 30 * RT.day { old.append(url) }
        }
        try RT.shot("untracked.png", in: h.folder, age: 50 * RT.day, now: now)
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)

        let off = await tool.run(["clean"])
        #expect(off.exit == .error && off.stderr == "error: \(Copy.Shortcuts.retentionOff.key)\n")

        h.preferences.retention = RT.policy(h.folder)
        let dry = await tool.run(["clean", "--dry-run"])
        #expect(dry.stdout == "would move 2 screenshots (\(CLIRender.bytes(old.map { RT.file($0).size }.reduce(0, +)))) to the Trash:\n"
            + old.map { canon($0) + "\n" }.joined())
        #expect(h.trasher.trashed.isEmpty, "a dry run moves nothing")

        let json = await tool.run(["clean", "--json"])
        let report = try ControlProtocol.decoder().decode(ControlCleanup.self, from: Data(json.stdout.utf8))
        #expect(report.count == 2 && !report.dryRun && report.files.isEmpty)
        #expect(Set(h.trasher.trashed) == ["old 1.png", "old 2.png"])
        #expect(h.timers.isEmpty, "cleanup plays no Peg moment")
        #expect(await tool.run(["clean"]).stdout == "nothing to clean up\n")
    }

    @Test func nothingChangesBeforeTheTour() async throws {
        let h = try ModelHarness(onboardingShown: false)
        defer { h.tearDown() }
        await h.ledger.record(RT.file(try RT.shot("shot.png", in: h.folder, age: 60, now: RT.now())))
        h.preferences.retention = RT.policy(h.folder)
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        for arguments in [["pause"], ["resume"], ["copy"], ["latest"], ["clean"], ["clean", "--dry-run"]] {
            let out = await tool.run(arguments)
            #expect(out.exit == .error, "\(arguments)")
            #expect(out.stderr == "error: \(Copy.Shortcuts.notSetUp.key)\n")
        }
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(status.pausedBy == .setup && !status.copying && status.folder == nil && status.latest == nil)
        #expect(h.preferences.copyEnabled)
        #expect(h.pasteboard.writes.isEmpty && h.trasher.trashed.isEmpty)
        #expect(h.events.starts == 0, "the folder was not touched")
    }

    /// Copying stops when macOS saves no file: status says so instead of "on".
    @Test func statusSaysWhenAnAttentionStopsCopying() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        let tool = h.tool(dir)
        h.prefs.set("clipboard", forKey: "target")
        h.model.refreshStatus()
        #expect(await eventually { await h.model.attentions.contains(.destinationNotFile) })
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(!status.copying && status.pausedBy == nil)
        #expect(status.attention == ["destinationNotFile"])
        let text = await tool.run([]).stdout
        #expect(text.contains("copying: needs attention (macOS saves screenshots to the clipboard or an app, not to a file)"))
        #expect(text.contains("attention: macOS saves screenshots"))
    }

    /// While the launch still asks whether a Focus is on, a pause is plain "paused", not
    /// called the user's.
    @Test func whileTheFocusIsUnknownAPauseIsPlain() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        #expect(await h.start())
        let (server, dir) = try h.controlServer()
        defer { server.stop() }
        h.preferences.copyEnabled = false
        h.model.focusStateKnown = false
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await h.tool(dir).run(["--json"]).stdout.utf8))
        #expect(!status.copying && status.pausedBy == nil && status.attention == [])
        #expect(await h.tool(dir).run([]).stdout.contains("copying: paused\n"))
        h.model.focusStateKnown = true
    }

    // MARK: Right after a launch

    /// ClipShot was just launched and binds its socket a moment later: the tool waits for it.
    @Test func aJustLaunchedAppIsWaitedFor() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let dir = try CT.shortDir()
        let server = try StubHandler().server(at: CT.socket(in: dir))
        defer { server.stop() }
        let late = Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            try? server.start()
        }
        let out = await h.tool(dir, appRunning: true, launchedRecently: true).run(["status", "--json"])
        await late.value
        #expect(out.exit == .ok, "\(out.stderr)")
        #expect(try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(out.stdout.utf8)) == StubHandler.status)
    }

    /// Not running is said at once: no waiting for a socket that cannot come.
    @Test func notRunningIsSaidAtOnce() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        var tool = h.tool(try CT.shortDir(), appRunning: false, launchedRecently: true)
        tool.startupGrace = .seconds(5)
        let started = ContinuousClock.now
        #expect(await tool.run(["pause"]).exit == .notRunning)
        #expect(ContinuousClock.now - started < .seconds(1), "no retry while ClipShot is not running")
    }

    /// Running, just launched, and the socket never comes: unavailable, after the grace.
    @Test func aSocketThatNeverComesIsUnavailableAfterTheGrace() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        var tool = h.tool(try CT.shortDir(), appRunning: true, launchedRecently: true)
        tool.startupGrace = .milliseconds(200)
        let started = ContinuousClock.now
        let out = await tool.run(["pause", "--json"])
        #expect(ContinuousClock.now - started >= .milliseconds(200))
        #expect(out.exit == .error && out.stdout.contains(#""code":"socketUnavailable""#))
    }

    // MARK: Without the app

    /// ClipShot runs but its socket does not answer (it could not start it): said as such,
    /// with what to do, never "not running".
    @Test func aRunningAppWithoutItsSocketIsNotCalledNotRunning() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let tool = h.tool(try CT.shortDir(), appRunning: true)
        for arguments in [["pause"], ["status"], ["clean", "--dry-run"]] {
            let out = await tool.run(arguments + ["--json"])
            #expect(out.exit == .error, "\(arguments)")
            #expect(out.stdout.contains(#""code":"socketUnavailable""#))
            #expect(out.stderr.contains("ClipShot is running, but its control socket is not available"))
            #expect(out.stderr.contains("quit ClipShot and open it again"))
        }
    }

    /// Without the app, status still says why cleanup would not run.
    @Test func offlineStatusReportsTheRetentionRefusal() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let stored = Preferences(store: InMemoryPreferenceStore())
        stored.onboardingShown = true
        stored.retention = RT.policy(try Fixtures.makeDir())
        let tool = h.tool(try CT.shortDir(), offline: stored)
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(status.retention.refusal == "notConfirmed")
        #expect(await tool.run([]).stdout.contains("cleanup: after 30 days, paused until you check"))
        stored.retention = RT.policy(h.folder)
        let confirmed = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(confirmed.retention.refusal == nil)
    }

    /// The real sources read and never write: no ledger, no log, no settings file appear.
    @Test func liveOfflineSourcesWriteNothing() async throws {
        let support = try CT.shortDir()
        let domain = "sk.moravcik.ClipShot.tests.\(UUID().uuidString)"
        let sources = CLIOfflineSources.live(supportDirectory: support, appDefaultsDomain: domain, findsRunningApp: false)
        #expect(!sources.appRunning())
        let tool = CommandLineTool(
            version: "0.9.0", socket: CT.socket(in: support), workingDirectory: support, offline: sources)
        // Never set up in that domain: refused before the folder is read.
        let latest = await tool.run(["latest"])
        #expect(latest.stderr == "error: \(Copy.Shortcuts.notSetUp.key)\n")
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(status.pausedBy == .notRunning && status.folder == nil && status.latest == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(domain).plist")
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func commandsThatNeedTheAppExitWithThree() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let tool = h.tool(try CT.shortDir())
        for arguments in [["pause"], ["resume"], ["copy"], ["copy", "x.png"], ["clean"], ["clean", "--dry-run"]] {
            let out = await tool.run(arguments)
            #expect(out.exit == .notRunning, "\(arguments)")
            #expect(out.stderr == "error: ClipShot is not running. Start it with: open -a ClipShot\n")
        }
        #expect(await tool.run(["pause", "--json"]).stdout.contains(#""code":"notRunning""#))
    }

    /// `latest` and `status` read the ledger and the folder themselves while the app is not
    /// running, with the same selection, and change nothing.
    @Test func latestAndStatusWorkWithoutTheApp() async throws {
        let h = try ModelHarness()
        defer { h.tearDown() }
        let now = RT.now()
        let older = try RT.shot("older.png", in: h.folder, age: 200, now: now)
        let newer = try RT.shot("newer.png", in: h.folder, age: 100, now: now)
        for url in [older, newer] { await h.ledger.record(RT.file(url)) }
        try RT.shot("untracked.png", in: h.folder, age: 10, now: now)
        let stored = Preferences(store: InMemoryPreferenceStore())
        stored.onboardingShown = true
        stored.retention = RT.policy(h.folder, days: 14)
        let tool = h.tool(try CT.shortDir(), offline: stored)

        #expect(await tool.run(["latest", "-n", "3"]) == CLIOutput(stdout: "\(canon(newer))\n\(canon(older))\n"))
        let status = try ControlProtocol.decoder().decode(ControlStatus.self, from: Data(await tool.run(["--json"]).stdout.utf8))
        #expect(status == ControlStatus(
            running: false, appVersion: nil, copying: false, pausedBy: .notRunning, folder: h.folder.path,
            retention: ControlStatus.Retention(enabled: true, days: 14, refusal: nil), latest: canon(newer)))
        #expect(await tool.run([]).stdout.hasPrefix("app: not running (start it: open -a ClipShot)\ncopying: off while ClipShot is not running\n"))

        // Before the tour: refused, as the app refuses.
        let fresh = h.tool(try CT.shortDir(), offline: Preferences(store: InMemoryPreferenceStore()))
        let refused = await fresh.run(["latest"])
        #expect(refused.exit == .error && refused.stderr == "error: \(Copy.Shortcuts.notSetUp.key)\n")
        #expect(h.pasteboard.writes.isEmpty)
    }
}
