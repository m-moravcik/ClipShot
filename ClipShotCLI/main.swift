import Foundation

// `clipshot`: hands the arguments to `CommandLineTool` (ClipShot/Control) and prints what it
// returns. The version is the app's: both are built from the same MARKETING_VERSION, and the
// tool carries it in its own embedded Info.plist, so it is right wherever the binary is
// linked from.

let environment = ProcessInfo.processInfo.environment
let support = environment[ControlProtocol.supportDirectoryEnvironmentKey].map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? ControlProtocol.supportDirectory
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

let output = await CommandLineTool(
    version: version,
    socket: support.appendingPathComponent(ControlProtocol.socketName),
    workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    offline: .live(supportDirectory: support)
).run(Array(CommandLine.arguments.dropFirst()))

FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.exit.rawValue)
