// spikeax - dump / press accessibility elements of a process (used to drive the Cmd+Shift+5
// toolbar, its Options menu and the Markup window). Needs Accessibility for the terminal.
// Usage: spikeax dump <pid> [maxDepth]        prints "<n> role 'title' 'desc' (x,y wxh)"
//        spikeax press <pid> <n> [action]     performs AXPress (or the given action) on element n
import Foundation
import ApplicationServices
setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
let pid = pid_t(a[2])!
let app = AXUIElementCreateApplication(pid)
AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
var all: [AXUIElement] = []
func walk(_ e: AXUIElement, _ depth: Int, _ maxDepth: Int, _ out: Bool) {
    let n = all.count; all.append(e)
    if out {
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
        let val = (attr(e, kAXValueAttribute)).map { "\($0)" } ?? ""
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        print("\(n) \(String(repeating: " ", count: depth))\(role) '\(title)' '\(desc)' v='\(val.prefix(40))' (\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))")
    }
    guard depth < maxDepth else { return }
    var kids = (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    if depth == 0 && kids.isEmpty { kids = (attr(e, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    for c in kids { walk(c, depth + 1, maxDepth, out) }
}
let maxDepth = a.count > 3 && a[1] == "dump" ? Int(a[3])! : 12
switch a[1] {
case "dump": walk(app, 0, maxDepth, true)
case "press":
    walk(app, 0, 12, false)
    let r = AXUIElementPerformAction(all[Int(a[3])!], (a.count > 4 ? a[4] : kAXPressAction) as CFString)
    print("perform rc=\(r.rawValue)")
default: print("usage"); exit(2)
}
