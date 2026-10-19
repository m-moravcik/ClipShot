// spikeprefs - read/write com.apple.screencapture through CFPreferences, the way ClipShot will.
// Usage:
//   spikeprefs set <key> <string|bool:true|bool:false>   (CFPreferencesSetValue + AppSynchronize)
//   spikeprefs del <key>
//   spikeprefs get                                        (prints the keys ClipShot cares about)
//   spikeprefs watch [seconds]                            (long-lived: AppSynchronize + read every 500 ms,
//                                                          prints only when a value changes)
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let app = "com.apple.screencapture" as CFString
let keys = ["location", "location-screenshot", "location-screenrecording", "show-thumbnail",
            "target", "target-screenshot", "target-screenrecording", "type", "style"]

func read() -> [String: String] {
    CFPreferencesAppSynchronize(app)
    var out: [String: String] = [:]
    for k in keys {
        let v = CFPreferencesCopyAppValue(k as CFString, app)
        out[k] = v.map { "\($0)" } ?? "<nil>"
    }
    return out
}
func dump(_ d: [String: String]) -> String { keys.map { "\($0)=\(d[$0]!)" }.joined(separator: " ") }

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "set":
    let raw = args[3]
    let value: CFPropertyList = raw == "bool:true" ? true as NSNumber : raw == "bool:false" ? false as NSNumber : raw as NSString
    CFPreferencesSetValue(args[2] as CFString, value, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let ok = CFPreferencesAppSynchronize(app)
    print("set \(args[2])=\(raw) synchronize=\(ok)")
case "del":
    CFPreferencesSetValue(args[2] as CFString, nil, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    print("del \(args[2]) synchronize=\(CFPreferencesAppSynchronize(app))")
case "get":
    print(dump(read()))
case "watch":
    let secs = args.count > 2 ? Double(args[2])! : 120
    var last = read()
    print("\(Date()) initial \(dump(last))")
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        usleep(500_000)
        let cur = read()
        if cur != last { print("\(Date()) changed \(dump(cur))"); last = cur }
    }
    print("\(Date()) watch end")
default:
    print("usage: spikeprefs set|del|get|watch"); exit(2)
}
