import AppKit
import CoreImage
import QuartzCore
import TegiCore

final class Scene: NSObject {
    struct Window {
        var id: WindowID
        var frame: CGRect
        var ring: Color?
        var radius: Double
        var floating: Bool
        var depth: CGFloat = 0
        var image: IOSurface?
        var icon: NSImage?
    }

    typealias Content = [[Window]]

    private struct WorkspaceLayers {
        let container = CALayer()
        let shadow = CALayer()
        let background = CALayer()
        let paper = CALayer()
    }

    private let panel: ScenePanel
    private let view = SceneView()
    private let host = CALayer()
    private let root = CALayer()
    private var workspaces: [WorkspaceLayers] = []
    private var cards: [WindowID: CALayer] = [:]
    private var depths: [WindowID: CGFloat] = [:]
    private let ring = CALayer()
    private let hint = CALayer()
    private let backdrop = CALayer()
    private var labels: [CATextLayer] = []
    private var notice: CATextLayer?
    private var index: Spring
    private var zoom: Spring
    private var link: CADisplayLink?
    private var anchor: Double?
    private let size: CGSize
    private var wallpaper: Any?
    private let wallpaperFrame: CGRect
    private let config: Config
    private var drag: (id: WindowID, start: CGPoint, offset: CGPoint, moving: Bool, home: CALayer?, frame: CGRect)?
    private(set) var inOverview = false
    private var tracking = false

    var isSettled: Bool { link == nil && !tracking && !inOverview }

    var onFinished: () -> Void = {}
    var onPick: (WindowID) -> Void = { _ in }
    var onPickWorkspace: (Int) -> Void = { _ in }
    var onScroll: (NSEvent) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onHint: (_ workspace: Int, _ point: CGPoint) -> CGRect? = { _, _ in nil }
    var onDrop: (_ id: WindowID, _ workspace: Int, _ point: CGPoint) -> Void = { _, _, _ in }
    var onDropBetween: (_ id: WindowID, _ index: Int) -> Void = { _, _ in }

    init(area: CGRect, screen: CGRect, wallpaper: Any?, paper: IOSurface?, config: Config) {
        size = area.size
        self.wallpaper = wallpaper
        wallpaperFrame = CGRect(x: screen.minX - area.minX, y: screen.minY - area.minY, width: screen.width, height: screen.height)
        self.config = config
        index = Spring(from: 0, to: 0, start: 0)
        zoom = Spring(from: 1, to: 1, start: 0)
        panel = ScenePanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        // Apps under an opaque window stop drawing, and this one stays on screen while hidden.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // The default animation shrinks and fades the panel, blurring the handover to the real windows.
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.ignoresMouseEvents = true
        // A layer-hosting view needs its layer before wantsLayer. AppKit owns that layer and may unhide it,
        // so everything visible lives one level down, where only tegi shows and hides it.
        view.layer = host
        view.wantsLayer = true
        root.frame = CGRect(origin: .zero, size: area.size)
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.backgroundColor = cgColor(config.backdropColor)
        backdrop.frame = wallpaperFrame
        backdrop.contentsGravity = .resizeAspectFill
        // The bare wallpaper: the desktop capture also holds icons and widgets, right for an empty workspace but not behind them.
        backdrop.contents = backdropImage(paper ?? wallpaper)
        // Workspaces are inserted by index from the bottom, so the backdrop keeps behind them by depth, not order.
        backdrop.zPosition = -1
        // Dimmed over black: darkening the picture itself crushes a dark wallpaper's shadows.
        backdrop.opacity = 0.75
        if config.overviewBackdrop == .wallpaper { root.backgroundColor = CGColor(gray: 0, alpha: 1) }
        root.addSublayer(backdrop)
        host.addSublayer(root)
        panel.contentView = view
        view.onMouseDown = { [weak self] p in self?.mouseDown(p) }
        view.onMouseDragged = { [weak self] p in self?.mouseDragged(p) }
        view.onMouseUp = { [weak self] p in self?.mouseUp(p) }
        view.onScroll = { [weak self] e in self?.onScroll(e) }
        view.onKey = { [weak self] code in
            if code == 53 || code == 36 { self?.onClose() }
        }
        ring.borderWidth = config.focusRingWidth
        hint.backgroundColor = cgColor(Color(hex: "#7fc8ff80")!)
        hint.cornerRadius = 6
        // Shown by unhiding layers: ordering in or fading a window takes effect frames after the motion starts.
        root.isHidden = true
        panel.orderFrontRegardless()
    }

    var isVisible: Bool { !root.isHidden }

    func setWallpaper(_ image: Any?, paper: IOSurface?) {
        wallpaper = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ws in workspaces { ws.paper.contents = image }
        backdrop.contents = backdropImage(paper ?? image)
        CATransaction.commit()
    }
    var currentIndex: Double { index.value(at: CACurrentMediaTime()) }

    private static let blur = CIContext()

    // Blurred small: a few hundred pixels are plenty for a blur, and keep a new wallpaper cheap.
    private func backdropImage(_ wallpaper: Any?) -> CGImage? {
        guard config.overviewBackdrop == .wallpaper, let wallpaper else { return nil }
        let image: CIImage
        if CFGetTypeID(wallpaper as CFTypeRef) == IOSurfaceGetTypeID() {
            image = CIImage(ioSurface: unsafeBitCast(wallpaper as AnyObject, to: IOSurfaceRef.self))
        } else if CFGetTypeID(wallpaper as CFTypeRef) == CGImage.typeID {
            image = CIImage(cgImage: wallpaper as! CGImage)
        } else {
            return nil
        }
        // About 900 pixels across, whatever size it came in, so the blur looks the same.
        let k = min(1, 900 / max(image.extent.width, 1))
        let small = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let soft = small.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: small.extent)
        return Self.blur.createCGImage(soft, from: small.extent)
    }

    /// The names shown in each workspace's corner while the overview is open.
    func setNames(_ names: [String]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while labels.count < names.count {
            let label = CATextLayer()
            label.fontSize = 13
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.foregroundColor = CGColor(gray: 1, alpha: 1)
            label.backgroundColor = CGColor(gray: 1, alpha: 0.12)
            label.cornerRadius = 11
            label.alignmentMode = .center
            label.contentsScale = panel.backingScaleFactor
            label.opacity = 0
            root.addSublayer(label)
            labels.append(label)
        }
        while labels.count > names.count { labels.removeLast().removeFromSuperlayer() }
        for (label, name) in zip(labels, names) {
            label.string = name
            let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
            label.bounds = CGRect(x: 0, y: 0, width: ceil(width) + 20, height: 22)
        }
        CATransaction.commit()
        place(at: CACurrentMediaTime())
    }

    func show(_ content: Content, at index: Double) {
        update(content, animated: false)
        let now = CACurrentMediaTime()
        self.index = Spring(from: index, to: index, start: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(at: now)
        root.isHidden = false
        CATransaction.commit()
    }

    func update(_ content: Content, animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while workspaces.count < content.count {
            let ws = WorkspaceLayers()
            ws.container.anchorPoint = CGPoint(x: 0, y: 1)
            ws.container.bounds = CGRect(origin: .zero, size: size)
            ws.shadow.frame = ws.container.bounds
            ws.shadow.shadowColor = CGColor(gray: 0, alpha: 1)
            ws.shadow.shadowOpacity = 0
            ws.shadow.shadowRadius = 20
            ws.shadow.shadowOffset = CGSize(width: 0, height: -10)
            ws.shadow.shadowPath = CGPath(rect: ws.container.bounds.insetBy(dx: -10, dy: -10), transform: nil)
            ws.background.frame = ws.container.bounds
            ws.background.masksToBounds = true
            ws.background.backgroundColor = CGColor(gray: 0.25, alpha: 1)
            ws.paper.frame = wallpaperFrame
            ws.paper.contents = wallpaper
            ws.paper.contentsGravity = .resizeAspectFill
            ws.background.addSublayer(ws.paper)
            ws.container.addSublayer(ws.shadow)
            ws.container.addSublayer(ws.background)
            root.insertSublayer(ws.container, at: UInt32(workspaces.count))
            workspaces.append(ws)
        }
        while workspaces.count > content.count { workspaces.removeLast().container.removeFromSuperlayer() }

        var seen: Set<WindowID> = []
        ring.removeFromSuperlayer()
        for (w, windows) in content.enumerated() {
            for win in windows {
                seen.insert(win.id)
                depths[win.id] = win.depth
                // The dragged window stays where the pointer has it, but keeps the ring if it's the focused one.
                guard drag?.id != win.id || drag?.moving != true else {
                    if let color = win.ring, let card = cards[win.id] { wear(color, card, radius: win.radius) }
                    continue
                }
                let card = cards[win.id] ?? makeCard(win)
                cards[win.id] = card
                if card.superlayer !== workspaces[w].container {
                    workspaces[w].container.addSublayer(card)
                    card.frame = flip(win.frame)
                } else {
                    move(card, to: flip(win.frame), animated: animated)
                }
                card.zPosition = win.depth
                if let image = win.image, card.contents == nil { setContents(image, of: card) }
                card.cornerRadius = win.radius
                if let color = win.ring { wear(color, card, radius: win.radius) }
            }
        }
        for (id, card) in cards where !seen.contains(id) {
            card.removeFromSuperlayer()
            cards[id] = nil
            depths[id] = nil
        }
        CATransaction.commit()
    }

    private func wear(_ color: Color, _ card: CALayer, radius: Double) {
        ring.borderColor = cgColor(color)
        ring.cornerRadius = radius + config.focusRingWidth
        ring.frame = card.bounds.insetBy(dx: -config.focusRingWidth, dy: -config.focusRingWidth)
        card.addSublayer(ring)
    }

    func setContents(_ contents: IOSurface, for id: WindowID) {
        guard let card = cards[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setContents(contents, of: card)
        CATransaction.commit()
    }

    private func setContents(_ contents: Any, of card: CALayer) {
        card.contents = contents
        card.backgroundColor = nil
        card.sublayers?.filter { $0 !== ring && $0.name != "badge" }.forEach { $0.removeFromSuperlayer() }
    }

    private func makeCard(_ win: Window) -> CALayer {
        let card = CALayer()
        card.contentsGravity = .resize
        card.cornerRadius = win.radius
        card.masksToBounds = false
        card.name = String(win.id)
        if config.overviewIcons, let icon = win.icon {
            // Sized so it shows at 26 points once the overview has zoomed out.
            let side = 26 / config.overviewZoom, inset = 10 / config.overviewZoom
            let badge = CALayer()
            badge.name = "badge"
            badge.contents = icon
            badge.contentsGravity = .resizeAspect
            badge.frame = CGRect(x: inset, y: inset, width: side, height: side)
            badge.zPosition = 1
            badge.opacity = 0
            badge.shadowOpacity = 0.3
            badge.shadowRadius = 3 / config.overviewZoom
            badge.shadowOffset = CGSize(width: 0, height: -1 / config.overviewZoom)
            card.addSublayer(badge)
        }
        if let image = win.image {
            card.contents = image
        } else {
            card.backgroundColor = CGColor(gray: 0.32, alpha: 1)
            if let icon = win.icon {
                let l = CALayer()
                l.contents = icon
                l.contentsGravity = .resizeAspect
                l.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
                l.position = CGPoint(x: win.frame.width / 2, y: win.frame.height / 2)
                card.addSublayer(l)
            }
        }
        return card
    }

    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }

    private func move(_ card: CALayer, to frame: CGRect, animated: Bool) {
        guard card.frame != frame else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let p = config.animations.spring(.windowMovement) {
            let now = card.presentation() ?? card
            let k = config.animations.slowdown
            for (key, from, to) in [("position", NSValue(point: now.position), NSValue(point: CGPoint(x: frame.midX, y: frame.midY))),
                                    ("bounds.size", NSValue(size: now.bounds.size), NSValue(size: frame.size))] {
                let a = CASpringAnimation(keyPath: key)
                a.mass = 1
                a.stiffness = p.stiffness / (k * k)
                a.damping = 2 * p.dampingRatio * p.stiffness.squareRoot() / k
                a.fromValue = from
                a.toValue = to
                a.duration = Spring(from: 0, to: 1, start: 0, params: p, slowdown: k).duration
                card.add(a, forKey: key)
            }
        }
        card.frame = frame
    }

    func slide(to target: Int, velocity: Double? = nil) {
        tracking = false
        index = spring(index, to: Double(target), .workspaceSwitch, velocity: velocity)
        run()
    }

    private func spring(_ current: Spring, to target: Double, _ name: Animations.Name, velocity: Double? = nil) -> Spring {
        let now = CACurrentMediaTime()
        guard let params = config.animations.spring(name) else { return Spring(from: target, to: target, start: now) }
        return Spring(from: current.value(at: now), to: target, velocity: velocity ?? current.velocity(at: now), start: now,
                      params: params, slowdown: config.animations.slowdown)
    }

    func track(_ position: Double) {
        tracking = true
        let now = CACurrentMediaTime()
        index = Spring(from: position, to: position, start: now)
        place(at: now)
    }

    func openOverview(needsAccess: Bool = false) {
        if needsAccess && notice == nil {
            let notice = CATextLayer()
            notice.string = "Allow Screen Recording for tegi in System Settings to see your windows here"
            notice.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            notice.fontSize = 15
            notice.foregroundColor = CGColor(gray: 0.85, alpha: 1)
            notice.alignmentMode = .center
            notice.contentsScale = panel.backingScaleFactor
            notice.frame = CGRect(x: 0, y: 24, width: size.width, height: 22)
            notice.zPosition = 10
            root.addSublayer(notice)
            self.notice = notice
        }
        inOverview = true
        panel.ignoresMouseEvents = false
        zoom = spring(zoom, to: config.overviewZoom, .overviewOpenClose)
        panel.makeKeyAndOrderFront(nil)
        run()
    }

    func closeOverview(at target: Int) {
        inOverview = false
        tracking = false
        panel.ignoresMouseEvents = true
        cancelDrag()
        notice?.removeFromSuperlayer()
        notice = nil
        zoom = spring(zoom, to: 1, .overviewOpenClose)
        index = spring(index, to: Double(target), .overviewOpenClose)
        run()
    }

    func hide() {
        anchor = nil
        link?.invalidate()
        link = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.isHidden = true
        CATransaction.commit()
    }

    func close() {
        hide()
        panel.orderOut(nil)
    }

    private func run() {
        guard link == nil else { return }
        anchor = CACurrentMediaTime() - 0.05
        let link = panel.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        // The window server may show the picture's first frame late, so motion starts one frame after it.
        if let anchor {
            self.anchor = nil
            let start = link.targetTimestamp + (link.targetTimestamp - link.timestamp)
            if index.start >= anchor && index.start < start { index.start = start }
            if zoom.start >= anchor && zoom.start < start { zoom.start = start }
        }
        let t = link.targetTimestamp
        place(at: t)
        if index.isDone(at: t) && zoom.isDone(at: t) {
            self.link?.invalidate()
            self.link = nil
            if !inOverview && !tracking { onFinished() }
        }
    }

    private func place(at t: Double) {
        let z = zoom.value(at: t), r = index.value(at: t)
        let w = size.width * z, h = size.height * z, gap = size.height * config.overviewGap * z
        let x = (size.width - w) / 2, top = (size.height - h) / 2
        let progress = config.overviewZoom < 1 ? min(max((1 - z) / (1 - config.overviewZoom), 0), 1) : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Corners, names and icons belong to the overview, so they grow in with it and are gone at full size.
        let radius = config.overviewWorkspaceRadius * progress / max(z, 0.01)
        for (i, ws) in workspaces.enumerated() {
            let y = (Double(i) - r) * (h + gap) + top
            ws.container.position = CGPoint(x: x, y: size.height - y)
            ws.container.transform = CATransform3DMakeScale(z, z, 1)
            ws.shadow.shadowOpacity = Float(progress * 0x50 / 255)
            if ws.background.cornerRadius != radius {
                ws.background.cornerRadius = radius
                ws.shadow.shadowPath = CGPath(roundedRect: ws.container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            if labels.indices.contains(i) {
                let label = labels[i]
                // Above the workspace, in the gap, so it never covers a window.
                label.position = CGPoint(x: x + label.bounds.width / 2, y: size.height - y + 6 + label.bounds.height / 2)
                label.opacity = config.overviewLabels ? Float(progress) : 0
            }
        }
        if config.overviewIcons {
            for card in cards.values { card.sublayers?.first { $0.name == "badge" }?.opacity = Float(progress) }
        }
        CATransaction.commit()
    }

    private func workspace(at point: CGPoint) -> (index: Int, local: CGPoint)? {
        for (i, ws) in workspaces.enumerated() {
            let layer = ws.container.presentation() ?? ws.container
            let local = layer.convert(point, from: root.presentation() ?? root)
            if local.y >= 0 && local.y <= size.height {
                return (i, CGPoint(x: local.x, y: size.height - local.y))
            }
        }
        return nil
    }

    private func gap(at point: CGPoint) -> (index: Int, bar: CGRect)? {
        let frames = workspaces.map { ($0.container.presentation() ?? $0.container).frame }
        guard let first = frames.first else { return nil }
        let thickness = 6.0
        if point.y > first.maxY {
            return (0, CGRect(x: first.minX, y: first.maxY + 8, width: first.width, height: thickness))
        }
        for i in 0..<(frames.count - 1) where point.y < frames[i].minY && point.y > frames[i + 1].maxY {
            let mid = (frames[i].minY + frames[i + 1].maxY) / 2
            return (i + 1, CGRect(x: frames[i].minX, y: mid - thickness / 2, width: frames[i].width, height: thickness))
        }
        return nil
    }

    private func card(at point: CGPoint) -> WindowID? {
        guard let hit = (root.presentation() ?? root).hitTest(point) else { return nil }
        var layer: CALayer? = hit
        while let l = layer, l.name == nil { layer = l.superlayer }
        return layer?.name.flatMap { WindowID($0) }
    }

    private func mouseDown(_ point: CGPoint) {
        guard inOverview else { return }
        if let id = card(at: point), let layer = cards[id] {
            let frame = layer.superlayer.map { root.convert(layer.frame, from: $0) } ?? layer.frame
            drag = (id, point, CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), false, layer.superlayer, layer.frame)
        } else {
            drag = nil
        }
    }

    private func mouseDragged(_ point: CGPoint) {
        guard inOverview, var d = drag, let layer = cards[d.id] else { return }
        if !d.moving {
            guard hypot(point.x - d.start.x, point.y - d.start.y) > 6 else { return }
            d.moving = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Lifted out of its zoomed workspace at the same size on screen: scaled, not resized, so the ring and badge inside scale with it.
            if let parent = layer.superlayer {
                let frame = root.convert(layer.frame, from: parent)
                let z = zoom.value(at: CACurrentMediaTime())
                layer.removeFromSuperlayer()
                layer.transform = CATransform3DMakeScale(z, z, 1)
                layer.position = CGPoint(x: frame.midX, y: frame.midY)
            }
            layer.zPosition = 20
            layer.opacity = 0.75
            root.addSublayer(layer)
            CATransaction.commit()
            drag = d
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = layer.frame.size
        layer.position = CGPoint(x: point.x - d.offset.x + size.width / 2, y: point.y - d.offset.y + size.height / 2)
        if let (w, local) = workspace(at: point), let rect = onHint(w, local) {
            if hint.superlayer !== workspaces[w].container { workspaces[w].container.addSublayer(hint) }
            hint.zPosition = 5
            hint.frame = flip(rect)
            hint.isHidden = false
        } else if let (_, bar) = gap(at: point) {
            if hint.superlayer !== root { root.addSublayer(hint) }
            hint.zPosition = 15
            hint.frame = bar
            hint.isHidden = false
        } else {
            hint.isHidden = true
        }
        CATransaction.commit()
    }

    private func mouseUp(_ point: CGPoint) {
        guard inOverview else { return }
        let d = drag
        drag = nil
        guard let d else {
            if let (w, _) = workspace(at: point) { onPickWorkspace(w) } else { onClose() }
            return
        }
        guard d.moving else { return onPick(d.id) }
        hint.removeFromSuperlayer()
        guard let layer = cards[d.id] else { return }
        guard let (w, local) = workspace(at: point) else {
            if let (index, _) = gap(at: point) {
                layer.removeFromSuperlayer()
                cards[d.id] = nil
                return onDropBetween(d.id, index)
            }
            return putBack(layer, d.home, d.frame)
        }
        do {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let frame = workspaces[w].container.convert(layer.frame, from: root)
            layer.removeFromSuperlayer()
            layer.transform = CATransform3DIdentity
            layer.frame = frame
            layer.opacity = 1
            layer.zPosition = depths[d.id] ?? 0
            workspaces[w].container.addSublayer(layer)
            CATransaction.commit()
            onDrop(d.id, w, local)
        }
    }

    private func cancelDrag() {
        hint.removeFromSuperlayer()
        if let d = drag, d.moving, let layer = cards[d.id] { putBack(layer, d.home, d.frame) }
        drag = nil
    }

    private func putBack(_ layer: CALayer, _ home: CALayer?, _ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        layer.transform = CATransform3DIdentity
        layer.frame = frame
        layer.opacity = 1
        layer.zPosition = layer.name.flatMap { WindowID($0) }.flatMap { depths[$0] } ?? 0
        home?.addSublayer(layer)
        CATransaction.commit()
    }
}

private final class ScenePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class SceneView: NSView {
    var onMouseDown: (CGPoint) -> Void = { _ in }
    var onMouseDragged: (CGPoint) -> Void = { _ in }
    var onMouseUp: (CGPoint) -> Void = { _ in }
    var onScroll: (NSEvent) -> Void = { _ in }
    var onKey: (UInt16) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { onMouseUp(convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) { onScroll(event) }
    override func keyDown(with event: NSEvent) { onKey(event.keyCode) }
}

func cgColor(_ c: Color) -> CGColor { CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }
