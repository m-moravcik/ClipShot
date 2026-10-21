import Foundation

// `clipshot`: hands the arguments to `CommandLineTool` (ClipShot/Control) and prints what it
// returns. The version is the app's: both are built from the same MARKETING_VERSION, and the
// tool carries it in its own embedded Info.plist, so it is right wherever the binary is
// linked from.

let environment = ProcessInfo.processInfo.environment
let override = environment[ControlProtocol.supportDirectoryEnvironmentKey].map { URL(fileURLWithPath: $0, isDirectory: true) }
let support = override ?? ControlProtocol.supportDirectory
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
// Debug builds only, and only with another support folder: the app's settings from another
// defaults domain, so the binary's tests never read the real ones. A release build always
// reads the app's own domain.
#if DEBUG
let domain = override == nil ? nil : environment[ControlProtocol.defaultsDomainEnvironmentKey]
#else
let domain: String? = nil
#endif

let output = await CommandLineTool(
    version: version,
    socket: support.appendingPathComponent(ControlProtocol.socketName),
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    offline: .live(supportDirectory: support, appDefaultsDomain: domain ?? "sk.moravcik.ClipShot", findsRunningApp: override == nil)
).run(Array(CommandLine.arguments.dropFirst()))

FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.exit.rawValue)
