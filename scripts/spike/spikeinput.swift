// spikeinput - post real HID-level input so global screenshot shortcuts and hover work.
// Needs Accessibility for the responsible process (the terminal that runs it).
// Usage:
//   spikeinput trusted
//   spikeinput key <keycode> [cmd,shift,ctrl,opt]     e.g. key 20 cmd,shift  (Cmd+Shift+3)
//   spikeinput move <x> <y>                           global points, top-left origin
//   spikeinput click <x> <y>
//   spikeinput drag <x1> <y1> <x2> <y2> [steps]
//   spikeinput pos
import Foundation
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in s.split(separator: ",") {
        switch m { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift)
        case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); default: break }
    }
    return f
}
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
func mouse(_ t: CGEventType, _ p: CGPoint) { post(CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)) }

switch a.count > 1 ? a[1] : "" {
case "trusted":
    print("AXIsProcessTrusted=\(AXIsProcessTrusted())")
case "key":
    let code = CGKeyCode(a[2])!
    let f = a.count > 3 ? flags(a[3]) : []
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
    usleep(30_000)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
case "move":
    mouse(.mouseMoved, pt(2))
case "click":
    let p = pt(2); mouse(.mouseMoved, p); usleep(50_000)
    mouse(.leftMouseDown, p); usleep(60_000); mouse(.leftMouseUp, p)
case "drag":
    let p1 = pt(2), p2 = pt(4); let steps = a.count > 6 ? Int(a[6])! : 30
    mouse(.mouseMoved, p1); usleep(80_000); mouse(.leftMouseDown, p1); usleep(80_000)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t)); usleep(15_000)
    }
    usleep(80_000); mouse(.leftMouseUp, p2)
case "pos":
    print(CGEvent(source: nil)?.location ?? .zero)
default:
    print("usage: spikeinput trusted|key|move|click|drag|pos"); exit(2)
}
