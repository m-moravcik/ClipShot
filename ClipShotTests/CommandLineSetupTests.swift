import Foundation
import Testing
@testable import ClipShot

/// Settings > General > Command line: what the section reports, and the link Install makes.
/// Every path is in a temporary folder that stands for "/"; nothing here reads or writes
/// /usr/local/bin, /opt/homebrew/bin or ~/.local/bin, and Install runs without the password
/// prompt (`asAdministrator: false`) into those temporary folders only.
@Suite("Command line setup")
struct CommandLineSetupTests {
    /// A fake "/" with the app, Homebrew's bin, /usr/local/bin and ~/.local/bin.
    struct Root {
        let root: URL
        let helper: URL
        let brewBin: URL
        let localBin: URL
        let userBin: URL
        let home: URL

        init(app: String = "Applications/ClipShot.app", makeHelper: Bool = true, makeBins: Bool = true) throws {
            root = try Fixtures.makeDir().resolvingSymlinksInPath()
            home = root.appending(path: "Users/you")
            helper = root.appending(path: app).appending(path: "Contents/Helpers/clipshot")
            brewBin = root.appending(path: "opt/homebrew/bin")
            localBin = root.appending(path: "usr/local/bin")
            userBin = home.appending(path: ".local/bin")
            if makeHelper { try Self.tool(at: helper) }
            if makeBins {
                for folder in [brewBin, localBin, userBin] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
            }
        }

        static func tool(at url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho clipshot\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func locations(homebrew: Bool = false) -> CommandLineLocations {
            CommandLineLocations(
                helper: helper,
                candidates: [brewBin, localBin, userBin].map { $0.appending(path: "clipshot") },
                installTarget: localBin.appending(path: "clipshot"),
                isHomebrewCopy: homebrew,
                home: home,
                displayRoot: root)
        }

        func link(_ folder: URL, to target: String) throws {
            try FileManager.default.createSymbolicLink(
                atPath: folder.appending(path: "clipshot").path, withDestinationPath: target)
        }

        func status(homebrew: Bool = false) -> CommandLineStatus {
            .detect(locations(homebrew: homebrew))
        }
    }

    // MARK: Detection

    @Test("Nothing anywhere: not installed, and Install links /usr/local/bin/clipshot")
    func nothingInstalled() throws {
        let fs = try Root()
        #expect(fs.status() == .notInstalled)
        let action = fs.status().action(installTarget: fs.locations().installTarget)
        #expect(action?.link == fs.localBin.appending(path: "clipshot"))
        #expect(action?.replacing == nil)
    }

    @Test("A link to this app's tool is found in each place a shell looks", arguments: [0, 1, 2])
    func linkedAnywhere(index: Int) throws {
        let fs = try Root()
        let folder = [fs.brewBin, fs.localBin, fs.userBin][index]
        try fs.link(folder, to: fs.helper.path)
        #expect(fs.status() == .linked(folder.appending(path: "clipshot")))
        #expect(fs.status().action(installTarget: fs.locations().installTarget) == nil)
    }

    @Test("A relative link, or one through a linked folder, still counts as this app's")
    func linkedThroughIndirection() throws {
        let fs = try Root()
        // /usr/local/bin/clipshot -> ../../../Applications/ClipShot.app/Contents/Helpers/clipshot
        try fs.link(fs.localBin, to: "../../../Applications/ClipShot.app/Contents/Helpers/clipshot")
        #expect(fs.status() == .linked(fs.localBin.appending(path: "clipshot")))

        // The app reached through a symlinked folder, as /Applications can be.
        let other = try Root(makeHelper: false)
        let real = other.root.appending(path: "Volumes/Apps/ClipShot.app/Contents/Helpers/clipshot")
        try Root.tool(at: real)
        try FileManager.default.createDirectory(
            at: other.root.appending(path: "Applications"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: other.root.appending(path: "Applications/ClipShot.app"),
            withDestinationURL: other.root.appending(path: "Volumes/Apps/ClipShot.app"))
        try other.link(other.localBin, to: real.path)
        #expect(other.status() == .linked(other.localBin.appending(path: "clipshot")))
    }

    @Test("A Homebrew copy never offers Install, with or without the cask's link")
    func homebrewNeverOffersInstall() throws {
        let fs = try Root()
        #expect(fs.status(homebrew: true) == .homebrew(nil))
        try fs.link(fs.brewBin, to: fs.helper.path)
        #expect(fs.status(homebrew: true) == .homebrew(fs.brewBin.appending(path: "clipshot")))
        #expect(fs.status(homebrew: true).action(installTarget: fs.locations().installTarget) == nil)
    }

    @Test("A dangling link (the app moved) is stale: Fix replaces exactly that link")
    func danglingLinkIsStale() throws {
        let fs = try Root()
        let gone = fs.root.appending(path: "Applications/Old/ClipShot.app/Contents/Helpers/clipshot").path
        try fs.link(fs.localBin, to: gone)
        let link = fs.localBin.appending(path: "clipshot")
        #expect(fs.status() == .stale(link, target: gone, missing: true))
        let action = fs.status().action(installTarget: fs.locations().installTarget)
        #expect(action?.link == link)
        #expect(action?.replacing == gone)
    }

    @Test("A link to another ClipShot.app's tool is stale too, and fixable")
    func otherCopyIsStale() throws {
        let fs = try Root()
        let other = fs.home.appending(path: "Downloads/ClipShot.app/Contents/Helpers/clipshot")
        try Root.tool(at: other)
        try fs.link(fs.userBin, to: other.path)
        let link = fs.userBin.appending(path: "clipshot")
        #expect(fs.status() == .stale(link, target: other.path, missing: false))
        #expect(fs.status().action(installTarget: fs.locations().installTarget)?.link == link)
    }

    @Test("A regular file, or a link to some other program, is refused: no action, no prompt")
    func foreignIsNeverReplaced() throws {
        let copy = try Root()
        // What `make install-cli` leaves: a copy, not a link.
        try Root.tool(at: copy.localBin.appending(path: "clipshot"))
        #expect(copy.status() == .foreign(copy.localBin.appending(path: "clipshot")))
        #expect(copy.status().action(installTarget: copy.locations().installTarget) == nil)

        let unrelated = try Root()
        let program = unrelated.root.appending(path: "usr/local/Cellar/clipshot-other/1.0/bin/clipshot")
        try Root.tool(at: program)
        try unrelated.link(unrelated.localBin, to: program.path)
        #expect(unrelated.status() == .foreign(unrelated.localBin.appending(path: "clipshot")))
        #expect(unrelated.status().action(installTarget: unrelated.locations().installTarget) == nil)

        let folder = try Root()
        try FileManager.default.createDirectory(
            at: folder.localBin.appending(path: "clipshot"), withIntermediateDirectories: true)
        #expect(folder.status() == .foreign(folder.localBin.appending(path: "clipshot")))
    }

    @Test("A stale link anywhere is reported before a working one, which it may shadow")
    func staleBeforeLinked() throws {
        let fs = try Root()
        try fs.link(fs.localBin, to: fs.helper.path)
        let gone = fs.root.appending(path: "nowhere/ClipShot.app/Contents/Helpers/clipshot").path
        try fs.link(fs.userBin, to: gone)
        #expect(fs.status() == .stale(fs.userBin.appending(path: "clipshot"), target: gone, missing: true))
    }

    @Test("A working link wins over a foreign copy elsewhere")
    func linkedBeforeForeign() throws {
        let fs = try Root()
        try Root.tool(at: fs.userBin.appending(path: "clipshot"))
        try fs.link(fs.localBin, to: fs.helper.path)
        #expect(fs.status() == .linked(fs.localBin.appending(path: "clipshot")))
    }

    @Test("No tool in the bundle: the section is hidden")
    func noToolIsUnavailable() throws {
        let fs = try Root(makeHelper: false)
        #expect(fs.status() == .unavailable)
    }

    @Test("A translocated app (opened from Downloads unmoved) asks to be moved first")
    func translocatedNeedsMove() throws {
        let fs = try Root(app: "private/var/folders/xy/AppTranslocation/1F2E/d/ClipShot.app")
        #expect(fs.status() == .needsMove)
        #expect(fs.status().action(installTarget: fs.locations().installTarget) == nil)
    }

    @Test("Missing bin folders read as nothing installed")
    func missingFolders() throws {
        let fs = try Root(makeBins: false)
        #expect(fs.status() == .notInstalled)
    }

    // MARK: Locations

    @Test("Live locations: Homebrew's prefix first, no duplicates, the tool in Contents/Helpers")
    func liveLocations() {
        let home = URL(fileURLWithPath: "/Users/you")
        let app = URL(fileURLWithPath: "/Applications/ClipShot.app")
        let custom = CommandLineLocations.live(
            bundleURL: app, environment: ["HOMEBREW_PREFIX": "/opt/homebrew"], home: home)
        #expect(custom.candidates.map(\.path)
            == ["/opt/homebrew/bin/clipshot", "/usr/local/bin/clipshot", "/Users/you/.local/bin/clipshot"])
        #expect(custom.helper.path == "/Applications/ClipShot.app/Contents/Helpers/clipshot")
        #expect(custom.installTarget.path == "/usr/local/bin/clipshot")

        let other = CommandLineLocations.live(bundleURL: app, environment: ["HOMEBREW_PREFIX": "/srv/brew"], home: home)
        #expect(other.candidates.first?.path == "/srv/brew/bin/clipshot")
        #expect(other.candidates.count == 4)
    }

    @Test("Paths are shown with ~ for home, and from the fake root")
    func display() throws {
        let fs = try Root()
        let locations = fs.locations()
        #expect(locations.display(fs.userBin.appending(path: "clipshot")) == "~/.local/bin/clipshot")
        #expect(locations.display(fs.localBin.appending(path: "clipshot")) == "/usr/local/bin/clipshot")
    }

    @Test("Copy Command quotes the app's path for the shell")
    func manualCommand() {
        var locations = CommandLineLocations(
            helper: URL(fileURLWithPath: "/Applications/ClipShot.app/Contents/Helpers/clipshot"),
            candidates: [], installTarget: URL(fileURLWithPath: "/usr/local/bin/clipshot"),
            isHomebrewCopy: false, home: URL(fileURLWithPath: "/Users/you"))
        #expect(locations.manualCommand
            == "sudo mkdir -p /usr/local/bin && sudo ln -s /Applications/ClipShot.app/Contents/Helpers/clipshot /usr/local/bin/clipshot")
        locations.helper = URL(fileURLWithPath: "/Users/you/My Apps/It's $(here)/ClipShot.app/Contents/Helpers/clipshot")
        #expect(locations.manualCommand.contains(
            "sudo ln -s '/Users/you/My Apps/It'\\''s $(here)/ClipShot.app/Contents/Helpers/clipshot' /usr/local/bin/clipshot"))
        #expect(CommandLineLocations.shellQuoted("") == "''")
    }

    @Test("The password prompt only where the folder, or its nearest existing parent, is not the user's")
    func needsAdministrator() throws {
        let fs = try Root()
        #expect(!CommandLineSetup.needsAdministrator(fs.localBin))
        #expect(!CommandLineSetup.needsAdministrator(fs.root.appending(path: "not/yet/there")))
        let locked = fs.root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(CommandLineSetup.needsAdministrator(locked))
        #expect(CommandLineSetup.needsAdministrator(locked.appending(path: "bin")))
    }

    // MARK: The linker, run for real without the prompt

    private func link(_ fs: Root, at link: URL, replacing: String? = nil, helper: URL? = nil) async -> CommandLineLinkResult {
        await ScriptLinker().link(
            helper: helper ?? fs.helper, at: link, replacing: replacing, asAdministrator: false, prompt: "test")
    }

    private func target(of link: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    }

    @Test("Install creates the folder and the link, naming the app's path as given")
    func installCreatesFolderAndLink() async throws {
        let fs = try Root(makeBins: false)
        let link = fs.localBin.appending(path: "clipshot")
        #expect(await self.link(fs, at: link) == .linked)
        #expect(target(of: link) == fs.helper.path)
        #expect(fs.status() == .linked(link))
    }

    @Test("Install never replaces anything already there")
    func installRefusesExisting() async throws {
        let fs = try Root()
        let link = fs.localBin.appending(path: "clipshot")
        try Data("mine".utf8).write(to: link)
        #expect(await self.link(fs, at: link) == .changed)
        #expect(try Data(contentsOf: link) == Data("mine".utf8))

        let dangling = try Root()
        let other = dangling.localBin.appending(path: "clipshot")
        try dangling.link(dangling.localBin, to: "/nowhere/clipshot")
        #expect(await self.link(dangling, at: other) == .changed)
        #expect(target(of: other) == "/nowhere/clipshot")

        // A folder at the path: ln would otherwise put the link inside it.
        let folder = try Root()
        let path = folder.localBin.appending(path: "clipshot")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        #expect(await self.link(folder, at: path) == .changed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty)
    }

    @Test("Fix replaces the stale link only while it still points where it did")
    func fixReplacesOnlyTheSeenLink() async throws {
        let fs = try Root()
        let link = fs.localBin.appending(path: "clipshot")
        let gone = fs.root.appending(path: "Old/ClipShot.app/Contents/Helpers/clipshot").path
        try fs.link(fs.localBin, to: gone)
        // Changed since it was checked: left alone.
        #expect(await self.link(fs, at: link, replacing: "/somewhere/else") == .changed)
        #expect(target(of: link) == gone)
        // As seen: replaced, and no temporary link left beside it.
        #expect(await self.link(fs, at: link, replacing: gone) == .linked)
        #expect(target(of: link) == fs.helper.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fs.localBin.path) == ["clipshot"])

        // A regular file where a link was expected is never replaced.
        let file = try Root()
        let path = file.localBin.appending(path: "clipshot")
        try Data("mine".utf8).write(to: path)
        #expect(await self.link(file, at: path, replacing: "mine") == .changed)
        #expect(try Data(contentsOf: path) == Data("mine".utf8))
    }

    @Test("Paths that look like shell code are passed as data, never run")
    func noInjection() async throws {
        let fs = try Root(
            app: "Apps/It's \"odd\" $(touch PWNED1) `touch PWNED2`; touch PWNED3 \\ & | > x/ClipShot.app")
        let bin = fs.root.appending(path: "bin $(touch PWNED4) 'q'")
        let link = bin.appending(path: "clipshot")
        #expect(await self.link(fs, at: link) == .linked)
        #expect(target(of: link) == fs.helper.path)
        // Nothing ran: no file named PWNED anywhere the shell could have written it.
        for folder in [fs.root, bin, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            #expect(!names.contains { $0.hasPrefix("PWNED") })
        }
        // The same for an expected target that looks like code.
        let stale = try Root()
        let staleLink = stale.localBin.appending(path: "clipshot")
        let odd = "/gone/$(touch PWNED5)/ClipShot.app/Contents/Helpers/clipshot"
        try stale.link(stale.localBin, to: odd)
        #expect(await self.link(stale, at: staleLink, replacing: odd) == .linked)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: stale.root.path)) ?? []).contains("PWNED5"))
    }

    @Test("No tool at the helper path: nothing is linked")
    func missingTool() async throws {
        let fs = try Root(makeHelper: false)
        let link = fs.localBin.appending(path: "clipshot")
        #expect(await self.link(fs, at: link) == .noTool)
        #expect(target(of: link) == nil)
    }

    @Test("osascript's answers: success, a cancelled prompt, the script's exit codes, other errors")
    func resultParsing() {
        #expect(ScriptLinker.result(of: "0\n") == .linked)
        #expect(ScriptLinker.result(of: "-128\nUser canceled.\n") == .cancelled)
        #expect(ScriptLinker.result(of: "64\n") == .noTool)
        #expect(ScriptLinker.result(of: "66\n") == .changed)
        #expect(ScriptLinker.result(of: "70\nln: x: Permission denied") == .failed("ln: x: Permission denied"))
        #expect(ScriptLinker.result(of: "70\n") == .failed("error 70"))
        #expect(ScriptLinker.result(of: "garbage") == .failed("garbage"))
    }

    // MARK: The section's model

    actor RecordingLinker: CommandLineLinking {
        let result: CommandLineLinkResult
        private(set) var calls: [(link: URL, replacing: String?, admin: Bool)] = []

        init(result: CommandLineLinkResult) { self.result = result }

        func link(
            helper: URL, at link: URL, replacing: String?, asAdministrator: Bool, prompt: String
        ) async -> CommandLineLinkResult {
            calls.append((link, replacing, asAdministrator))
            return result
        }
    }

    @Test("Install asks the linker for the right link, then says how it ended")
    @MainActor
    func setupInstall() async throws {
        let fs = try Root()
        let cancelled = RecordingLinker(result: .cancelled)
        let setup = CommandLineSetup(locations: fs.locations(), linker: cancelled)
        await setup.install()
        #expect(setup.activity == .ended(.cancelled))
        let calls = await cancelled.calls
        #expect(calls.count == 1)
        #expect(calls.first?.link == fs.localBin.appending(path: "clipshot"))
        #expect(calls.first?.replacing == nil)
        #expect(calls.first?.admin == false)
        setup.reset()
        #expect(setup.activity == .idle)
    }

    @Test("Nothing to install: the linker is never asked")
    @MainActor
    func setupNothingToDo() async throws {
        let fs = try Root()
        try Root.tool(at: fs.localBin.appending(path: "clipshot"))
        let linker = RecordingLinker(result: .linked)
        let setup = CommandLineSetup(locations: fs.locations(), linker: linker)
        await setup.install()
        #expect(await linker.calls.isEmpty)
        #expect(setup.activity == .idle)
    }

    @Test("A successful Install shows the new link")
    @MainActor
    func setupInstallsForReal() async throws {
        let fs = try Root()
        let setup = CommandLineSetup(locations: fs.locations(), linker: ScriptLinkerWithoutPrompt())
        await setup.install()
        #expect(setup.activity == .idle)
        #expect(setup.status == .linked(fs.localBin.appending(path: "clipshot")))
    }

    /// The real linker, with the prompt forced off whatever the folder says.
    struct ScriptLinkerWithoutPrompt: CommandLineLinking {
        func link(
            helper: URL, at link: URL, replacing: String?, asAdministrator: Bool, prompt: String
        ) async -> CommandLineLinkResult {
            await ScriptLinker().link(helper: helper, at: link, replacing: replacing, asAdministrator: false, prompt: prompt)
        }
    }
}
