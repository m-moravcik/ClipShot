// spikewindows - list on-screen windows owned by a pid (screencaptureui's owner *name* is the
// localised "Screenshot", so match by pid). Usage: spikewindows <pid>
import Foundation
import CoreGraphics
setvbuf(stdout, nil, _IOLBF, 0)
let pid = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? -1 : -1
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
print("\(clock_gettime_nsec_np(CLOCK_REALTIME)) pid=\(pid) onscreen=\(mine.count) " + mine.map {
    let b = $0[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return "[owner=\($0[kCGWindowOwnerName as String] ?? "?") layer=\($0[kCGWindowLayer as String] ?? "?") w=\(b["Width"] ?? "?") h=\(b["Height"] ?? "?")]"
}.joined(separator: " "))
