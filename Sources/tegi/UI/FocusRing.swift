import AppKit
import QuartzCore
import TegiCore

final class FocusRing {
    struct Target {
        var display: UInt32
        var screen: CGRect
        var frame: CGRect?
        var active: Bool
        var radius: Double = 0
        var window: CGWindowID = 0
    }

    struct Tabs {
        var display: UInt32
        var frame: CGRect
        var windows: [WindowID]
        var active: Int
    }

    var onPickTab: (WindowID) -> Void = { _ in }

    private final class Overlay {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        let ring = CALayer()
        var last: Drawn?
        var above: CGWindowID = 0

        init() {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.animationBehavior = .none
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.addSublayer(ring)
            window.contentView = view
            ring.isHidden = true
            // macOS rounds windows with a continuous curve; a circular ring parts from it at the corners.
            ring.cornerCurve = .continuous
        }
    }

    // Everything the ring is drawn from, so a settings change redraws it even when focus stays put.
    private struct Drawn: Equatable {
        var frame: CGRect
        var color: Color
        var width: Double
        var radius: Double
    }

    private var overlays: [UInt32: Overlay] = [:]
    private var hint: NSWindow?
    private var hintBelow: CGWindowID = 0
    private var tabPanels: [TabPanel] = []

    func update(_ targets: [Target], tabs: [Tabs], config: Config) {
        let wanted = Set(targets.map(\.display))
        for (id, overlay) in overlays where !wanted.contains(id) {
            overlay.window.orderOut(nil)
            overlays[id] = nil
        }
        for target in targets {
            let overlay = overlays[target.display] ?? Overlay()
            overlays[target.display] = overlay
            place(overlay, target, config)
        }
        placeTabs(tabs, targets, config)
    }

    private func screen(_ display: UInt32) -> NSScreen? { NSScreen.screens.first { $0.displayID == display } }

    // Directly above the window it rings, so whatever sits on top of that window covers the ring too. The ring is drawn
    // just outside the window, so the window coming forward past it doesn't hide it.
    private func show(_ overlay: Overlay, on screen: NSScreen, above window: CGWindowID) {
        if overlay.window.frame != screen.frame { overlay.window.setFrame(screen.frame, display: false) }
        guard !overlay.window.isVisible || overlay.above != window else { return }
        overlay.above = window
        if window != 0 { overlay.window.order(.above, relativeTo: Int(window)) } else { overlay.window.orderFrontRegardless() }
    }

    /// For after windows were reordered above the ringed ones.
    func restack() {
        for overlay in overlays.values where overlay.window.isVisible && overlay.above != 0 {
            overlay.window.order(.above, relativeTo: Int(overlay.above))
        }
    }

    private func local(_ frame: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: frame.minX - screen.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func place(_ overlay: Overlay, _ target: Target, _ config: Config) {
        guard config.focusRingWidth > 0, let frame = target.frame, let screen = screen(target.display) else {
            if !overlay.ring.isHidden {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                overlay.ring.isHidden = true
                CATransaction.commit()
            }
            overlay.last = nil
            return
        }
        show(overlay, on: screen, above: target.window)
        let w = config.focusRingWidth
        let rect = local(frame, in: target.screen).insetBy(dx: -w, dy: -w)
        let color = target.active ? config.focusRingColor : config.focusRingInactiveColor
        let drawn = Drawn(frame: rect, color: color, width: w, radius: target.radius)
        if !overlay.ring.isHidden, overlay.last == drawn { return }
        overlay.last = drawn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.ring.frame = rect
        overlay.ring.borderWidth = w
        overlay.ring.cornerRadius = target.radius + w
        overlay.ring.borderColor = cgColor(color)
        overlay.ring.isHidden = false
        CATransaction.commit()
    }

    func showHint(_ rect: CGRect?, below dragged: CGWindowID) {
        guard let rect, let top = NSScreen.screens.first?.frame.maxY else {
            hint?.orderOut(nil)
            hintBelow = 0
            return
        }
        let window = hint ?? makeHint()
        hint = window
        window.setFrame(CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height), display: false)
        if hintBelow != dragged || !window.isVisible {
            window.order(.below, relativeTo: Int(dragged))
            hintBelow = dragged
        }
    }

    private func makeHint() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = cgColor(Color(hex: "#7fc8ff80")!)
        view.layer?.cornerRadius = 6
        window.contentView = view
        return window
    }

    private func placeTabs(_ tabs: [Tabs], _ targets: [Target], _ config: Config) {
        while tabPanels.count > tabs.count { tabPanels.removeLast().orderOut(nil) }
        while tabPanels.count < tabs.count {
            let panel = TabPanel()
            panel.onPick = { [weak self] id in self?.onPickTab(id) }
            tabPanels.append(panel)
        }
        for (panel, tab) in zip(tabPanels, tabs) {
            guard let screen = screen(tab.display), let target = targets.first(where: { $0.display == tab.display }) else {
                panel.orderOut(nil)
                continue
            }
            let length = (tab.frame.height * 0.5).rounded()
            let rect = CGRect(x: tab.frame.minX - 5 - 4, y: tab.frame.minY + ((tab.frame.height - length) / 2).rounded(), width: 4, height: length)
            let flipped = local(rect, in: target.screen).offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
            panel.show(tab.windows, active: tab.active, frame: flipped)
        }
    }
}

private final class TabPanel: NSPanel {
    var onPick: (WindowID) -> Void = { _ in }
    private var windows: [WindowID] = []
    private let segments = CALayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let view = ClickView()
        view.wantsLayer = true
        view.layer?.addSublayer(segments)
        view.onClick = { [weak self] p in
            guard let self, !windows.isEmpty else { return }
            let i = Int((1 - p.y / max(frame.height, 1)) * Double(windows.count))
            onPick(windows[max(0, min(windows.count - 1, i))])
        }
        contentView = view
    }

    func show(_ windows: [WindowID], active: Int, frame: CGRect) {
        self.windows = windows
        if self.frame != frame { setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        segments.frame = CGRect(origin: .zero, size: frame.size)
        segments.sublayers?.forEach { $0.removeFromSuperlayer() }
        let each = frame.height / Double(max(windows.count, 1))
        for i in windows.indices {
            let s = CALayer()
            s.frame = CGRect(x: 0, y: frame.height - Double(i + 1) * each, width: frame.width, height: each)
            s.backgroundColor = cgColor(Color(hex: i == active ? "#ffc87f" : "#505050")!)
            segments.addSublayer(s)
        }
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }
}

private final class ClickView: NSView {
    var onClick: (CGPoint) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick(convert(event.locationInWindow, from: nil)) }
}
