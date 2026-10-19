// spikewatch - unprivileged screenshot-folder logger for the ClipShot platform spike.
// Usage: spikewatch <folder> [<folder>...]
// Prints two kinds of lines to stdout, each prefixed with a CLOCK_REALTIME ns timestamp:
//   FSE <eventId> <flags> <path>          - FSEvents (kFSEventStreamCreateFlagFileEvents, latency 0)
//   KQ <folder> <mask>                     - kqueue EVFILT_VNODE on the directory (O_EVTONLY), what a
//                                           DispatchSourceFileSystemObject-based watcher would see
//   POLL <state> <path> birth=.. mtime=.. ctime=.. size=.. isCap=0|1 capType=0|1 xattrs=[..]
// The poller runs every 2 ms, includes hidden files, and prints only when a file appears,
// changes (birth/mtime/ctime/size/xattr set), or disappears.
import Foundation
import CoreServices

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: spikewatch <folder> [<folder>...]\n".data(using: .utf8)!)
    exit(2)
}
let folders = CommandLine.arguments.dropFirst().map { ($0 as NSString).standardizingPath }

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }
func ns(_ t: timespec) -> UInt64 { UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec) }

let flagNames: [(UInt32, String)] = [
    (UInt32(kFSEventStreamEventFlagItemCreated), "Created"),
    (UInt32(kFSEventStreamEventFlagItemRemoved), "Removed"),
    (UInt32(kFSEventStreamEventFlagItemInodeMetaMod), "InodeMetaMod"),
    (UInt32(kFSEventStreamEventFlagItemRenamed), "Renamed"),
    (UInt32(kFSEventStreamEventFlagItemModified), "Modified"),
    (UInt32(kFSEventStreamEventFlagItemFinderInfoMod), "FinderInfoMod"),
    (UInt32(kFSEventStreamEventFlagItemChangeOwner), "ChangeOwner"),
    (UInt32(kFSEventStreamEventFlagItemXattrMod), "XattrMod"),
    (UInt32(kFSEventStreamEventFlagItemIsFile), "IsFile"),
    (UInt32(kFSEventStreamEventFlagItemIsDir), "IsDir"),
    (UInt32(kFSEventStreamEventFlagItemIsSymlink), "IsSymlink"),
    (UInt32(kFSEventStreamEventFlagItemCloned), "Cloned"),
    (UInt32(kFSEventStreamEventFlagMustScanSubDirs), "MustScanSubDirs"),
    (UInt32(kFSEventStreamEventFlagRootChanged), "RootChanged"),
    (UInt32(kFSEventStreamEventFlagHistoryDone), "HistoryDone"),
]
func describe(_ f: UInt32) -> String {
    let names = flagNames.filter { f & $0.0 != 0 }.map { $0.1 }
    return names.isEmpty ? String(format: "0x%x", f) : names.joined(separator: "|")
}

let callback: FSEventStreamCallback = { _, _, count, paths, flags, ids in
    let t = now()
    let arr = unsafeBitCast(paths, to: NSArray.self) as! [String]
    for i in 0..<count {
        print("\(t) FSE \(ids[i]) \(describe(flags[i])) \(arr[i])")
    }
}
var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
let createFlags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
guard let stream = FSEventStreamCreate(nil, callback, &ctx, folders as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.0, createFlags) else {
    print("FSEventStreamCreate failed"); exit(1)
}
let fseQueue = DispatchQueue(label: "fse")
FSEventStreamSetDispatchQueue(stream, fseQueue)
print("\(now()) FSEventStreamStart=\(FSEventStreamStart(stream))")

var kqSources: [DispatchSourceFileSystemObject] = []
for folder in folders {
    let fd = open(folder, O_EVTONLY)
    if fd < 0 { print("\(now()) KQ open failed \(folder) errno=\(errno)"); continue }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
        eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue: DispatchQueue(label: "kq"))
    src.setEventHandler { print("\(now()) KQ \(folder) mask=\(src.data.rawValue)") }
    src.resume()
    kqSources.append(src)
}

func xattrNames(_ path: String) -> [String] {
    let len = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard len > 0 else { return [] }
    var buf = [CChar](repeating: 0, count: len)
    _ = listxattr(path, &buf, len, XATTR_NOFOLLOW)
    return buf.split(separator: 0).map { String(cString: Array($0) + [0]) }
}

struct Snap: Equatable { var birth, mtime, ctime: UInt64; var size: Int64; var xattrs: [String] }
func snap(_ path: String) -> Snap? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return Snap(birth: ns(st.st_birthtimespec), mtime: ns(st.st_mtimespec), ctime: ns(st.st_ctimespec),
                size: st.st_size, xattrs: xattrNames(path).sorted())
}
func line(_ state: String, _ path: String, _ s: Snap) -> String {
    let isCap = s.xattrs.contains("com.apple.metadata:kMDItemIsScreenCapture") ? 1 : 0
    let capType = s.xattrs.contains("com.apple.metadata:kMDItemScreenCaptureType") ? 1 : 0
    return "POLL \(state) \(path) birth=\(s.birth) mtime=\(s.mtime) ctime=\(s.ctime) size=\(s.size) isCap=\(isCap) capType=\(capType) xattrs=\(s.xattrs)"
}

var known: [String: Snap] = [:]
let fm = FileManager.default
for folder in folders {
    for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
        let p = folder + "/" + name
        if let s = snap(p) { known[p] = s }
    }
}
print("\(now()) START folders=\(folders) preexisting=\(known.count)")

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "poll"))
timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
timer.setEventHandler {
    let t = now()
    var seen = Set<String>()
    for folder in folders {
      for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
        let p = folder + "/" + name
        seen.insert(p)
        guard let s = snap(p) else { continue }
        if let old = known[p] {
            if old != s { print("\(t) " + line("CHANGED", p, s)); known[p] = s }
        } else {
            print("\(t) " + line("NEW", p, s)); known[p] = s
        }
      }
    }
    for p in known.keys where !seen.contains(p) {
        print("\(t) POLL GONE \(p)"); known[p] = nil
    }
}
timer.resume()
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
dispatchMain()
