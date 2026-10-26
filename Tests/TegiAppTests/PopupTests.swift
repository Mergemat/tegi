import AppKit
import Testing
@testable import tegi

@MainActor @Test func menusArePopupsAndWindowsAreNot() throws {
    _ = NSApplication.shared
    func window(_ level: NSWindow.Level) -> NSWindow {
        // Off every display and clear, so a test run shows nothing.
        let w = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: 200, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.orderFront(nil)
        w.level = level
        CATransaction.flush()
        return w
    }
    let menu = window(.popUpMenu), plain = window(.normal), pinned = window(.floating)
    defer { [menu, plain, pinned].forEach { $0.close() } }
    #expect(isPopup(CGWindowID(menu.windowNumber)))
    #expect(!isPopup(CGWindowID(plain.windowNumber)))
    #expect(!isPopup(CGWindowID(pinned.windowNumber)))
}
