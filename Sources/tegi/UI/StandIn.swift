import AppKit
import QuartzCore

/// Live pictures of windows that take their place on screen while they resize, following the spring every frame. Each
/// shows what the app drew at its own size, pinned at the top left and cut to the frame, never scaled: the
/// compositor keeps the app drawing at least as large as the frame.
/// One per display, made ahead of time: a new window takes up to 100 ms to show anything, an existing one a frame.
final class StandIns {
    private struct Picture {
        let content: CALayer
        let live: CALayer
        let shadow: CALayer
        let radius: Double
        var leaving: Int?
        /// The compositor took it over. Until then it's on its way to being one, not one nobody owns.
        var claimed = false
    }

    let number: CGWindowID
    private let panel: NSPanel
    private let screen: CGRect
    // The main thread adds pictures, the compositor's thread moves and removes them.
    private let lock = NSLock()
    private var pictures: [CGWindowID: Picture] = [:]

    /// `screen` and frames are in global coordinates with the origin at the top left, like Accessibility's.
    init(screen: CGRect) {
        self.screen = screen
        let top = NSScreen.screens.first?.frame.height ?? screen.height
        panel = NSPanel(contentRect: CGRect(x: screen.minX, y: top - screen.maxY, width: screen.width, height: screen.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        // Shown once while empty, so the first resize finds the window already made on the server.
        panel.orderFrontRegardless()
        panel.orderOut(nil)
        number = CGWindowID(panel.windowNumber)
    }

    /// Main thread.
    func show(_ window: CGWindowID, at frame: CGRect, radius: Double) -> Bool {
        guard let live = LiveWindowLayer.make(window, gravity: "topLeft") else { return false }
        let content = CALayer(), shadow = CALayer()
        // Close to the shadow macOS draws for a window, so the swap back doesn't pop.
        shadow.shadowColor = CGColor(gray: 0, alpha: 1)
        shadow.shadowOpacity = 0.4
        shadow.shadowRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -10)
        content.masksToBounds = true
        content.cornerRadius = radius
        content.cornerCurve = .continuous
        live.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.addSublayer(live)
        let added = lock.withLock {
            guard pictures[window] == nil || pictures[window]?.leaving != nil else { return false }
            if let old = pictures[window] {
                old.content.removeFromSuperlayer()
                old.shadow.removeFromSuperlayer()
            }
            pictures[window] = Picture(content: content, live: live, shadow: shadow, radius: radius)
            return true
        }
        guard added else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.contentView!.layer!.addSublayer(shadow)
        panel.contentView!.layer!.addSublayer(content)
        CATransaction.commit()
        move(window, to: frame)
        // Directly above the frontmost window it stands in for; windows in front of that stay in front.
        if !panel.isVisible || isInFront(window) { panel.order(.above, relativeTo: Int(window)) }
        return true
    }

    /// Any thread, inside a transaction.
    func move(_ window: CGWindowID, to frame: CGRect) {
        lock.withLock {
            guard let p = pictures[window] else { return }
            let local = CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height)
            p.content.frame = local
            p.live.frame = p.content.bounds
            p.shadow.frame = local
            p.shadow.shadowPath = CGPath(roundedRect: p.shadow.bounds, cornerWidth: p.radius, cornerHeight: p.radius, transform: nil)
        }
    }

    /// The window came back. A window ordered back in takes a frame to show, so its picture stays two more.
    func retire(_ window: CGWindowID) {
        lock.withLock { pictures[window]?.leaving = 2 }
    }

    func claim(_ window: CGWindowID) {
        lock.withLock { pictures[window]?.claimed = true }
    }

    /// Retires every claimed picture but `owned`'s. Returns whether any was retired.
    func retireAll(except owned: Set<CGWindowID>) -> Bool {
        lock.withLock {
            var any = false
            for (window, p) in pictures where p.claimed && p.leaving == nil && !owned.contains(window) {
                pictures[window]?.leaving = 2
                any = true
            }
            return any
        }
    }

    /// Compositor thread, each frame. Returns whether pictures are still leaving.
    func step() -> Bool {
        let (left, empty) = lock.withLock { () -> (Bool, Bool) in
            var left = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (window, var p) in pictures {
                guard let frames = p.leaving else { continue }
                if frames > 0 {
                    p.leaving = frames - 1
                    pictures[window] = p
                    left = true
                } else {
                    p.content.removeFromSuperlayer()
                    p.shadow.removeFromSuperlayer()
                    pictures[window] = nil
                }
            }
            CATransaction.commit()
            return (left, pictures.isEmpty)
        }
        if empty {
            DispatchQueue.main.async { [self] in
                if lock.withLock({ pictures.isEmpty }) { panel.orderOut(nil) }
            }
        }
        return left
    }

    func close() { panel.close() }

    private func isInFront(_ window: CGWindowID) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        guard let mine = ids.firstIndex(of: number), let theirs = ids.firstIndex(of: window) else { return false }
        return theirs < mine
    }
}
