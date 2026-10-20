// F-markup probe 2: the system Markup extension through NSSharingService(named:).
// Build: swiftc -O scripts/spike/markup_share.swift -o /tmp/markup_share
// Run:   /tmp/markup_share <png>   (presents the editor over a probe window; Done prints the returned items)
import AppKit
let url = URL(fileURLWithPath: CommandLine.arguments[1])
final class D: NSObject, NSSharingServiceDelegate {
    var window: NSWindow?
    func sharingService(_ s: NSSharingService, willShareItems items: [Any]) { print("willShare", items) }
    func sharingService(_ s: NSSharingService, didShareItems items: [Any]) { print("didShare", items.map { type(of: $0) }, items) ; exit(0) }
    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) { print("didFail", error); exit(2) }
    func sharingService(_ s: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? { print("asked source window"); return window }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
w.makeKeyAndOrderFront(nil)
let d = D(); d.window = w
let s = NSSharingService(named: NSSharingService.Name("com.apple.MarkupUI.Markup"))!
s.delegate = d
print("canPerform", s.canPerform(withItems: [url]))
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    s.perform(withItems: [url])
    DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
        print("windows:", app.windows.map { "\(type(of: $0)) \($0.isVisible) sheets=\($0.sheets.count) \(String(describing: $0.attachedSheet.map { type(of: $0) }))" })
        exit(0)
    }
}
app.run()
