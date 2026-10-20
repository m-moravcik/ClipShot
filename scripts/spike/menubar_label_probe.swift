// Task 12e spike F-menubar-anim: what a MenuBarExtra label hands the status item.
//
// Five MenuBarExtras with different labels: a plain symbol in a framed ZStack, a symbol moved
// and squashed by a 30 Hz phase, a Canvas, a symbol with a repeating symbolEffect, and a shape
// moved by the phase. After 3 s and 3.5 s it writes each NSStatusBarButton's image (size,
// representation type, PNG) and a log to the folder given as the first argument, then quits
// after 40 s. Build as a throwaway LSUIElement bundle with its own bundle id:
//
//   swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos26.0 \
//       menubar_label_probe.swift -o Probe.app/Contents/MacOS/Probe
//
import SwiftUI
import AppKit

@MainActor @Observable final class Driver {
    var phase = 0
    private var timer: Timer?
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.phase += 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Probe.dump("t3") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { Probe.dump("t35") }
    }
}

@main
struct Spike2App: App {
    @State private var d: Driver
    init() { NSApplication.shared.setActivationPolicy(.accessory); let dd = Driver(); _d = State(initialValue: dd); dd.start() }
    var body: some Scene {
        MenuBarExtra { Text("L1") } label: {
            ZStack { Image(systemName: "camera.viewfinder") }.font(.system(size: 15)).frame(width: 22, height: 16)
        }
        MenuBarExtra { Text("L2") } label: {
            let u = sin(Double(d.phase % 30) / 30 * .pi)
            ZStack { Image(systemName: "doc.on.clipboard").scaleEffect(x: 1 + 0.2 * u, y: 1 - 0.3 * u, anchor: .bottom).offset(x: 4 * u) }
                .font(.system(size: 15)).frame(width: 22, height: 16)
        }
        MenuBarExtra { Text("L3") } label: {
            Canvas { ctx, _ in
                ctx.stroke(Path(roundedRect: CGRect(x: 2, y: 1, width: 18, height: 14), cornerRadius: 3), with: .foreground, lineWidth: 1.4)
            }.frame(width: 22, height: 16)
        }
        MenuBarExtra { Text("L4") } label: {
            ZStack { Image(systemName: "star.fill").symbolEffect(.bounce, options: .repeat(.continuous)) }.font(.system(size: 15)).frame(width: 22, height: 16)
        }
        MenuBarExtra { Text("L5") } label: {
            ZStack { RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.4).frame(width: 12, height: 14).offset(x: CGFloat(d.phase % 8)) }.frame(width: 22, height: 16)
        }
    }
}

@MainActor enum Probe {
    static func dump(_ tag: String) {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        var log = ""
        for (i, w) in NSApp.windows.enumerated() where String(describing: type(of: w)).contains("StatusBar") {
            func find(_ v: NSView) -> NSStatusBarButton? { if let b = v as? NSStatusBarButton { return b }; for s in v.subviews { if let b = find(s) { return b } }; return nil }
            guard let cv = w.contentView, let b = find(cv) else { continue }
            log += "\(tag) win\(i) frame=\(w.frame) image=\(b.image.map { "\($0.size)" } ?? "nil") reps=\(b.image?.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" } ?? [])\n"
            if let img = b.image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(tag)-win\(i).png"))
            }
        }
        if let h = FileHandle(forWritingAtPath: "\(dir)/log.txt") { h.seekToEndOfFile(); h.write(log.data(using: .utf8)!); h.closeFile() } else { try? log.write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8) }
    }
}
