import AppKit
_ = NSApplication.shared
import QuartzCore
// Drives focus-test: travel 5 columns, type, change workspace, type, click a window, type, go back, travel back, type.
// Posts real hotkeys, keys and clicks; samples every test window's on-screen frame every 4 ms; writes marks to events.log.
let dir = CommandLine.arguments[1]
let logPath = dir + "/events.log"
let log = FileHandle(forWritingAtPath: logPath)!
func mark(_ s: String) { log.seekToEndOfFile(); log.write(Data(String(format: "%.4f mark %@\n", CACurrentMediaTime(), s).utf8)) }
let hyper: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = flags; e.post(tap: .cghidEventTap)
    }
}
let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
func type(_ s: String, gap: Double = 0.03) { for ch in s { mark("type \(ch)"); key(codes[ch]!); usleep(UInt32(gap * 1e6)) } }
func hot(_ ch: Character, _ what: String) { mark("hot \(what)"); key(codes[ch]!, hyper) }
func wait(_ s: Double) { usleep(UInt32(s * 1e6)) }
func click(_ p: CGPoint) {
    mark("click \(Int(p.x)),\(Int(p.y))")
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
        usleep(15_000)
    }
}
// Sampler
var samples: [String] = []
let lock = NSLock(); var on = true
Thread.detachNewThread {
    var last = ""
    while true {
        lock.lock(); let go = on; lock.unlock(); if !go { break }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let s = list.filter { ($0[kCGWindowOwnerName as String] as? String ?? "").lowercased().hasPrefix("key") && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { w -> String? in
                guard let b = w[kCGWindowBounds as String] as? [String: Double], let n = w[kCGWindowNumber as String] as? Int else { return nil }
                return "\(n):\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))"
            }.sorted().joined(separator: " ")
        if s != last { lock.lock(); samples.append(String(format: "%.4f ", CACurrentMediaTime()) + s); lock.unlock(); last = s }
        usleep(4000)
    }
}
// The left column on the second workspace, which isn't the focused one there.
let screen = NSScreen.main!.frame
let clickAt = CGPoint(x: screen.width * 0.25, y: screen.height * 0.55)
wait(0.3)
mark("start")
for _ in 0..<5 { hot("l", "right"); wait(0.045) }
wait(0.03); type("hey")
wait(0.2); hot("u", "workspace-down"); wait(0.03); type("yo")
wait(0.25); click(clickAt); wait(0.04); type("ok")
wait(0.25); hot("i", "workspace-up"); wait(0.03); type("z")
wait(0.1)
for _ in 0..<5 { hot("h", "left"); wait(0.045) }
wait(0.03); type("w")
mark("end")
wait(1.0)
lock.lock(); on = false; lock.unlock(); wait(0.05)
try! samples.joined(separator: "\n").write(toFile: dir + "/frames.log", atomically: true, encoding: .utf8)
