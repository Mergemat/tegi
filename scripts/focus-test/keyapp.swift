import AppKit
import QuartzCore
// Test windows for focus-test: a plain app whose windows log every keystroke and focus change with the system clock, so a test can tell
// exactly when and where typing lands. Usage: keyapp <name> <windows>
let name = CommandLine.arguments[1], count = Int(CommandLine.arguments[2])!
let logPath = ProcessInfo.processInfo.environment["FOCUS_TEST_LOG"]!
let log = FileHandle(forWritingAtPath: logPath) ?? {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    return FileHandle(forWritingAtPath: logPath)!
}()
func note(_ s: String) { log.seekToEndOfFile(); log.write(Data(String(format: "%.4f %@\n", CACurrentMediaTime(), s).utf8)) }

final class Pad: NSTextView {
    var label = ""
    override func keyDown(with e: NSEvent) { note("key \(label) \(e.characters ?? "")"); super.keyDown(with: e) }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ n: Notification) {
        for i in 1...count {
            let w = NSWindow(contentRect: NSRect(x: 100 + i * 40, y: 100, width: 700, height: 500),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            let label = "\(name)\(i)"
            w.title = label
            let pad = Pad(frame: w.contentView!.bounds)
            pad.label = label
            pad.autoresizingMask = [.width, .height]
            pad.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
            pad.string = label + "\n"
            // Bright and saturated, so a test can find each window's edges in a recording.
            let hue = ["A": 0.0, "B": 0.33, "C": 0.55, "D": 0.8][name]! + Double(i) * 0.05
            pad.backgroundColor = NSColor(calibratedHue: hue, saturation: 0.75, brightness: 0.9, alpha: 1)
            pad.textColor = .white
            w.contentView = pad
            w.delegate = self
            w.makeFirstResponder(pad)
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ n: Notification) { note("keywin \((n.object as! NSWindow).title)") }
    // B and D behave like Finder: busy for a moment when they gain or lose focus.
    var heavy: Bool { name == "B" || name == "D" }
    func busy(_ s: Double) { let end = CACurrentMediaTime() + s; while CACurrentMediaTime() < end {} }
    func applicationDidBecomeActive(_ n: Notification) { note("active \(name)"); if heavy { busy(0.04) } }
    func applicationDidResignActive(_ n: Notification) { note("inactive \(name)"); if heavy { busy(0.06) } }
}
let app = NSApplication.shared
let d = Delegate()
app.delegate = d
app.setActivationPolicy(.regular)
app.run()
