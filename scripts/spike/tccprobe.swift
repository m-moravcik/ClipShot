// tccprobe - does touching ~/Desktop from a fresh ad-hoc signed build prompt, block, or fail?
// Built into a throwaway .app (see build-tccprobe.sh) so it is its own TCC responsible process.
// Usage: tccprobe <output-file> [folder]
import Foundation
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/stdout"
let folder = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : NSHomeDirectory() + "/Desktop"
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
let start = Date()
func log(_ s: String) {
    let line = String(format: "%8.3fs ", Date().timeIntervalSince(start)) + "[\(Thread.isMainThread ? "main" : "bg")] " + s + "\n"
    fh.write(line.data(using: .utf8)!)
}
log("start pid=\(getpid()) folder=\(folder)")
var done = false
DispatchQueue.global().async {
    let t0 = Date()
    let fd = open(folder, O_EVTONLY)
    let e = errno
    log(String(format: "open(O_EVTONLY) -> fd=%d errno=%d (%@) after %.3fs", fd, fd < 0 ? e : 0, fd < 0 ? String(cString: strerror(e)) : "ok", Date().timeIntervalSince(t0)))
    if fd >= 0 { close(fd) }
    let t1 = Date()
    do {
        let items = try FileManager.default.contentsOfDirectory(atPath: folder)
        log(String(format: "contentsOfDirectory -> %d items after %.3fs", items.count, Date().timeIntervalSince(t1)))
    } catch {
        log(String(format: "contentsOfDirectory -> error after %.3fs: %@", Date().timeIntervalSince(t1), "\(error)"))
    }
    done = true
}
for _ in 0..<40 where !done { Thread.sleep(forTimeInterval: 0.5); if !done { log("still waiting") } }
log(done ? "finished" : "gave up after 20s (call still blocked)")
exit(0)
