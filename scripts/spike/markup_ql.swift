// F-markup probe 1: Quick Look panel editing through its undocumented delegate selectors.
// Build: swiftc -O scripts/spike/markup_ql.swift -o /tmp/markup_ql
// Run:   /tmp/markup_ql <png> [saveMode]   (prints what the panel asks and whether Markup starts)
import AppKit
import Quartz
import ObjectiveC

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let wantedMode = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1") ?? 1

func ivars(_ cls: AnyClass) -> [String] {
    var n: UInt32 = 0
    guard let list = class_copyIvarList(cls, &n) else { return [] }
    defer { free(list) }
    return (0..<Int(n)).map { String(cString: ivar_getName(list[$0])!) }
}

final class Responder: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self; panel.delegate = self
        print("begin control")
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { print("end control") }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL }
    @objc(previewPanel:canEditItem:) func canEdit(_ panel: QLPreviewPanel, item: Any) -> Bool { print("asked canEditItem"); return true }
    @objc(previewPanel:saveModeForItem:) func saveMode(_ panel: QLPreviewPanel, item: Any) -> Int { print("asked saveModeForItem -> \(wantedMode)"); return wantedMode }
    @objc(previewPanel:didUpdateContentsOfPreviewItem:) func didUpdate(_ panel: QLPreviewPanel, item: Any) { print("didUpdateContents"); dump() }
    @objc(previewPanel:didSaveEditedCopyOfPreviewItem:atURL:) func didSaveCopy(_ panel: QLPreviewPanel, item: Any, at: URL) { print("didSaveEditedCopy at \(at.lastPathComponent)") }
}

func dump() {
    var st = stat(); lstat(url.path, &st)
    print("inode=\(st.st_ino) birth=\(st.st_birthtimespec.tv_sec) mtime=\(st.st_mtimespec.tv_sec)")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr"); p.arguments = [url.path]; try? p.run(); p.waitUntilExit()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let responder = Responder(frame: window.contentView!.bounds)
window.contentView!.addSubview(responder)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(responder)
app.activate(ignoringOtherApps: true)
dump()
print("QLPreviewPanel ivars:", ivars(QLPreviewPanel.self))
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let panel = QLPreviewPanel.shared()!
    panel.dataSource = responder; panel.delegate = responder
    panel.makeKeyAndOrderFront(nil)
    panel.reloadData()
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        print("panel visible:", panel.isVisible)
        print("windowController:", String(describing: panel.windowController), "currentController:", String(describing: panel.perform(NSSelectorFromString("currentController"))?.takeUnretainedValue()))
        if let obj = panel.windowController, obj.responds(to: NSSelectorFromString("markupEnabled")) {
            do {
                print("markupEnabled:", obj.value(forKey: "markupEnabled") ?? "nil")
                print("previewView:", String(describing: (obj.value(forKey: "previewView") as? NSObject).map { type(of: $0) }), "currentPreviewItem:", String(describing: panel.currentPreviewItem)); obj.perform(NSSelectorFromString("markupFromButton:"), with: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print("inMarkup:", obj.value(forKey: "inMarkup") ?? "nil", "isEditing:", obj.value(forKey: "isEditing") ?? "nil")
                    obj.perform(NSSelectorFromString("doneMarkup:"), with: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dump(); exit(0) }
                }
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("timeout"); exit(1) }
app.run()
