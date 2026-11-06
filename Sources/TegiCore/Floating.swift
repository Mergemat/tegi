import CoreGraphics

/// A window in its workspace's floating layer, which shows above the strip and doesn't scroll.
public struct Floater: Equatable {
    public let id: WindowID
    /// The top-left corner as a fraction of the working area, so a workspace keeps its arrangement on any display and
    /// gets it back exactly on the one it came from.
    public var origin: CGPoint
    public var size: CGSize

    public init(id: WindowID, frame: CGRect, in area: CGRect) {
        self.id = id
        size = frame.size
        origin = CGPoint(x: (frame.minX - area.minX) / max(area.width, 1), y: (frame.minY - area.minY) / max(area.height, 1))
    }

    /// Where it shows: enough of it stays on the display to grab, as niri and Mutter keep it, and its title bar never
    /// goes above the working area.
    public func frame(in area: CGRect) -> CGRect {
        let keepX = min(max(size.width / 4, 10), 75), keepY = min(max(size.height / 4, 10), 75)
        let x = area.minX + origin.x * area.width, y = area.minY + origin.y * area.height
        return CGRect(x: min(max(x, area.minX - size.width + keepX), area.maxX - keepX).rounded(),
                      y: max(min(y, area.maxY - keepY), area.minY).rounded(), width: size.width, height: size.height)
    }
}

/// Where a rule puts a window when it first floats: points in from a corner or side of the working area, or along a
/// side from its middle.
public struct FloatingPosition: Equatable {
    public enum Anchor: String, CaseIterable {
        case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
        case top, bottom, left, right
    }

    public var x: Double
    public var y: Double
    public var anchor: Anchor

    public init(x: Double, y: Double, anchor: Anchor = .topLeft) {
        self.x = x
        self.y = y
        self.anchor = anchor
    }

    func frame(_ size: CGSize, in area: CGRect) -> CGRect {
        let left = area.minX + x, right = area.maxX - size.width - x, midX = area.midX - size.width / 2 + x
        let top = area.minY + y, bottom = area.maxY - size.height - y, midY = area.midY - size.height / 2 + y
        let origin = switch anchor {
        case .topLeft: CGPoint(x: left, y: top)
        case .topRight: CGPoint(x: right, y: top)
        case .bottomLeft: CGPoint(x: left, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        case .top: CGPoint(x: midX, y: top)
        case .bottom: CGPoint(x: midX, y: bottom)
        case .left: CGPoint(x: left, y: midY)
        case .right: CGPoint(x: right, y: midY)
        }
        return CGRect(origin: origin, size: size)
    }
}

extension World {
    /// How far the move commands nudge a floating window.
    static let nudge = 50.0

    public func locateFloater(_ id: WindowID) -> (monitor: Int, workspace: Int, index: Int)? {
        for (m, mon) in monitors.enumerated() {
            for (w, ws) in mon.workspaces.enumerated() {
                if let i = ws.floaters.firstIndex(where: { $0.id == id }) { return (m, w, i) }
            }
        }
        return nil
    }

    /// Where a floating window shows on its display, whether or not its workspace does.
    public func floatingFrame(_ id: WindowID) -> CGRect? {
        guard let (m, w, i) = locateFloater(id) else { return nil }
        return monitors[m].workspaces[w].floaters[i].frame(in: monitors[m].area)
    }

    /// A window opening in the floating layer where its rule or its app puts it, or coming back, as from the Dock, where
    /// it floated last and on the display in use, as a tiled one does.
    public mutating func addFloating(_ id: WindowID, frame: CGRect?, rule: WindowRule = WindowRule(), config: Config) {
        let remembered = floatMemory.removeValue(forKey: id)
        let from = remembered != nil ? nil : frame.flatMap { f in monitors.firstIndex { $0.screen.contains(CGPoint(x: f.midX, y: f.midY)) } }
        guard locateFloater(id) == nil, let (m, w) = target(monitor: from, rule: rule) else { return }
        let area = monitors[m].area
        var floater = remembered
            ?? frame.map { Floater(id: id, frame: $0, in: monitors[from ?? m].area) }
            ?? Floater(id: id, frame: centered(CGSize(width: area.width * 0.6, height: area.height * 0.6), in: area), in: area)
        if remembered == nil, let width = rule.width { floater.size.width = Column.proportionWidth(width, geometry(m, config)) }
        if remembered == nil, let position = rule.position { floater = Floater(id: id, frame: position.frame(floater.size, in: area), in: area) }
        monitors[m].workspaces[w].floaters.append(floater)
        normalize(m)
    }

    /// From the strip to its workspace's floating layer: where it floated last, else where its rule puts it, else a
    /// little inside where it was tiled.
    public mutating func float(_ id: WindowID, rule: WindowRule = WindowRule(), config: Config) {
        guard let (m, w, c, t) = locate(id) else { return }
        let focused = focusedWindow == id
        let area = monitors[m].area
        let tiled = layout(config: config)[id]
        _ = monitors[m].workspaces[w].removeTile(c, t, geometry(m, config))
        var floater = floatMemory.removeValue(forKey: id)
        if floater == nil, let tiled {
            let inset = tiled.frame.insetBy(dx: tiled.frame.width * 0.05, dy: tiled.frame.height * 0.05)
            let frame = rule.position?.frame(inset.size, in: area) ?? (tiled.visible ? inset : centered(inset.size, in: area))
            floater = Floater(id: id, frame: frame, in: area)
        }
        monitors[m].workspaces[w].floaters.append(floater ?? Floater(id: id, frame: centered(area.size, in: area), in: area))
        if focused { monitors[m].workspaces[w].floatingActive = true }
        normalize(m)
    }

    /// From the floating layer into its workspace's strip, next to the active column.
    public mutating func tile(_ id: WindowID, rule: WindowRule = WindowRule(), config: Config) {
        guard let (m, w, i) = locateFloater(id) else { return }
        let focused = focusedWindow == id
        floatMemory[id] = monitors[m].workspaces[w].floaters.remove(at: i)
        insertColumn(id, m, w, rule: rule, focus: focused, config)
    }

    /// A floating window its app or the user moved. On another display, it joins the workspace showing there.
    public mutating func setFloatingFrame(_ id: WindowID, _ frame: CGRect) {
        guard let (m, w, i) = locateFloater(id) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let tm = monitors.firstIndex { $0.screen.contains(center) } ?? m
        let floater = Floater(id: id, frame: frame, in: monitors[tm].area)
        guard tm != m else {
            monitors[m].workspaces[w].floaters[i] = floater
            return
        }
        let focused = focusedWindow == id
        monitors[m].workspaces[w].floaters.remove(at: i)
        let tw = monitors[tm].active
        monitors[tm].workspaces[tw].floaters.append(floater)
        if focused {
            focusedMonitor = tm
            monitors[tm].workspaces[tw].floatingActive = true
        }
        for i in monitors.indices { normalize(i) }
    }

    /// A floating window dropped on a workspace in the overview, its title bar where the pointer let go of it.
    public mutating func dropFloating(_ id: WindowID, monitor m: Int, workspace w: Int, at point: CGPoint) {
        guard let (fm, fw, i) = locateFloater(id), monitors.indices.contains(m), monitors[m].workspaces.indices.contains(w) else { return }
        let size = monitors[fm].workspaces[fw].floaters[i].size, area = monitors[m].area
        let frame = CGRect(x: area.minX + point.x - size.width / 2, y: area.minY + point.y - 20, width: size.width, height: size.height)
        monitors[fm].workspaces[fw].floaters[i] = Floater(id: id, frame: frame, in: area)
        moveFloater(id, to: m, workspace: w, follow: false)
    }

    /// Where its workspace shows the floating layer, keeping its place on the display.
    mutating func moveFloater(_ id: WindowID, to m: Int, workspace w: Int, follow: Bool) {
        guard let (fm, fw, i) = locateFloater(id), monitors.indices.contains(m), monitors[m].workspaces.indices.contains(w) else { return }
        let floater = monitors[fm].workspaces[fw].floaters.remove(at: i)
        monitors[m].workspaces[w].floaters.append(floater)
        if follow {
            focusedMonitor = m
            activateWorkspace(m, w)
            monitors[m].workspaces[w].floatingActive = true
        }
        for i in monitors.indices { normalize(i) }
    }

    /// Focus to the floating layer (`true`), the strip (`false`) or the other one (nil), when it has a window.
    public mutating func focusLayer(floating: Bool?) {
        guard monitors.indices.contains(focusedMonitor) else { return }
        let a = monitors[focusedMonitor].active
        let ws = monitors[focusedMonitor].workspaces[a]
        let floating = floating ?? !ws.floatingFocused
        guard floating ? !ws.floaters.isEmpty : !ws.columns.isEmpty else { return }
        monitors[focusedMonitor].workspaces[a].floatingActive = floating
    }

    /// Focus goes to a floating window, which comes to the top of its layer.
    mutating func raise(_ id: WindowID) {
        guard let (m, w, i) = locateFloater(id) else { return }
        focusedMonitor = m
        activateWorkspace(m, w)
        let floater = monitors[m].workspaces[w].floaters.remove(at: i)
        monitors[m].workspaces[w].floaters.append(floater)
        monitors[m].workspaces[w].floatingActive = true
        normalize(m)
    }

    /// The command as it applies to the focused floating window. False: it isn't the floating layer's to handle.
    mutating func performFloating(_ command: Command, config: Config) -> Bool {
        let m = focusedMonitor, a = monitors[m].active
        let area = monitors[m].area, g = geometry(m, config)
        guard let top = monitors[m].workspaces[a].floaters.last else { return false }
        let frame = top.frame(in: area)

        func set(_ f: CGRect) {
            monitors[m].workspaces[a].floaters[monitors[m].workspaces[a].floaters.count - 1] = Floater(id: top.id, frame: f, in: area)
        }
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        func focus(_ d: Direction) -> Bool {
            let here = center(frame)
            let others = monitors[m].workspaces[a].floaters.dropLast().map { ($0.id, center($0.frame(in: area))) }
            let ahead = others.filter { _, p in
                switch d {
                case .left: p.x < here.x
                case .right: p.x > here.x
                case .up: p.y < here.y
                case .down: p.y > here.y
                case .next, .previous: false
                }
            }
            guard let next = ahead.min(by: { hypot($0.1.x - here.x, $0.1.y - here.y) < hypot($1.1.x - here.x, $1.1.y - here.y) }) else {
                return false
            }
            raise(next.0)
            return true
        }
        func focusFarthest(_ d: Direction) {
            let all = monitors[m].workspaces[a].floaters.map { ($0.id, center($0.frame(in: area))) }
            let pick = switch d {
            case .left: all.min { $0.1.x < $1.1.x }
            case .right: all.max { $0.1.x < $1.1.x }
            case .up: all.min { $0.1.y < $1.1.y }
            default: all.max { $0.1.y < $1.1.y }
            }
            if let pick, pick.0 != top.id { raise(pick.0) }
        }
        func moveTo(workspace w: Int, on tm: Int) {
            let w = max(0, min(monitors[tm].workspaces.count - 1, w))
            if tm != m || w != a { moveFloater(top.id, to: tm, workspace: w, follow: true) }
        }
        func resized(_ current: Double, _ change: SizeChange, full: Double) -> Double {
            let span = full - g.gap
            switch change {
            case .setFixed(let v): return v
            case .adjustFixed(let d): return current + d
            case .setProportion(let p): return span * p - g.gap
            case .adjustProportion(let d): return span * ((current + g.gap) / span + d) - g.gap
            }
        }
        func setSize(width: Double? = nil, height: Double? = nil) {
            var f = frame
            if let width { f.size.width = max(100, min(width, area.width)).rounded() }
            if let height { f.size.height = max(60, min(height, area.height)).rounded() }
            set(f)
        }
        func cycle(_ sizes: [Double], current: Double, forwards: Bool) -> Double? {
            guard !sizes.isEmpty else { return nil }
            return forwards ? sizes.first { current + 1 < $0 } ?? sizes[0] : sizes.last { $0 + 1 < current } ?? sizes[sizes.count - 1]
        }
        let widths = config.presetColumnWidths.map { w -> Double in
            switch w {
            case .proportion(let p): Column.proportionWidth(p, g)
            case .fixed(let px): px
            }
        }

        switch command {
        // The workspace and the display, not a window: the same with focus in either layer.
        case .focusWorkspaceUp, .focusWorkspaceDown, .focusWorkspace, .focusWorkspacePrevious,
             .moveWorkspaceUp, .moveWorkspaceDown, .moveWorkspaceToIndex, .setWorkspaceName, .unsetWorkspaceName,
             .focusMonitor, .moveWorkspaceToMonitor:
            return false

        case .focusColumnLeft: _ = focus(.left)
        case .focusColumnRight: _ = focus(.right)
        case .focusWindowUp: _ = focus(.up)
        case .focusWindowDown: _ = focus(.down)
        case .focusColumnFirst: focusFarthest(.left)
        case .focusColumnLast: focusFarthest(.right)
        case .focusWindowTop: focusFarthest(.up)
        case .focusWindowBottom: focusFarthest(.down)
        case .focusColumnRightOrFirst: if !focus(.right) { focusFarthest(.left) }
        case .focusColumnLeftOrLast: if !focus(.left) { focusFarthest(.right) }
        case .focusWindowDownOrTop: if !focus(.down) { focusFarthest(.up) }
        case .focusWindowUpOrBottom: if !focus(.up) { focusFarthest(.down) }
        case .focusWindowDownOrColumnLeft: if !focus(.down) { _ = focus(.left) }
        case .focusWindowDownOrColumnRight: if !focus(.down) { _ = focus(.right) }
        case .focusWindowUpOrColumnLeft: if !focus(.up) { _ = focus(.left) }
        case .focusWindowUpOrColumnRight: if !focus(.up) { _ = focus(.right) }
        case .focusColumnOrMonitorLeft: if !focus(.left) { focusMonitor(.left) }
        case .focusColumnOrMonitorRight: if !focus(.right) { focusMonitor(.right) }
        case .focusWindowOrMonitorUp: if !focus(.up) { focusMonitor(.up) }
        case .focusWindowOrMonitorDown: if !focus(.down) { focusMonitor(.down) }
        case .focusWindowOrWorkspaceUp: if !focus(.up) { activateWorkspace(m, a - 1) }
        case .focusWindowOrWorkspaceDown: if !focus(.down) { activateWorkspace(m, a + 1) }

        case .moveColumnLeft, .moveColumnLeftOrToMonitorLeft: set(frame.offsetBy(dx: -Self.nudge, dy: 0))
        case .moveColumnRight, .moveColumnRightOrToMonitorRight: set(frame.offsetBy(dx: Self.nudge, dy: 0))
        case .moveWindowUp, .moveWindowUpOrToWorkspaceUp: set(frame.offsetBy(dx: 0, dy: -Self.nudge))
        case .moveWindowDown, .moveWindowDownOrToWorkspaceDown: set(frame.offsetBy(dx: 0, dy: Self.nudge))

        case .moveColumnToWorkspaceUp, .moveWindowToWorkspaceUp: moveTo(workspace: a - 1, on: m)
        case .moveColumnToWorkspaceDown, .moveWindowToWorkspaceDown: moveTo(workspace: a + 1, on: m)
        case .moveColumnToWorkspace(let ref), .moveWindowToWorkspace(let ref):
            if let (tm, w) = resolve(ref) { moveTo(workspace: w, on: tm) }
        case .moveColumnToMonitor(let d), .moveWindowToMonitor(let d):
            if let tm = monitor(from: m, d) { moveTo(workspace: monitors[tm].active, on: tm) }

        case .centerColumn, .centerWindow: set(centered(frame.size, in: area))
        case .moveFloatingWindow(let x, let y):
            func to(_ change: SizeChange?, _ current: Double, _ full: Double) -> Double {
                switch change {
                case nil: current
                case .setFixed(let v): v
                case .adjustFixed(let d): current + d
                case .setProportion(let p): full * p
                case .adjustProportion(let d): current + full * d
                }
            }
            set(CGRect(x: area.minX + to(x, frame.minX - area.minX, area.width), y: area.minY + to(y, frame.minY - area.minY, area.height),
                       width: frame.width, height: frame.height))
        case .setColumnWidth(let change): setSize(width: resized(frame.width, change, full: area.width))
        case .setWindowHeight(let change): setSize(height: resized(frame.height, change, full: area.height))
        case .switchPresetColumnWidth, .switchPresetColumnWidthBack:
            setSize(width: cycle(widths, current: frame.width, forwards: command == .switchPresetColumnWidth))
        case .switchPresetWindowHeight:
            setSize(height: cycle(config.presetWindowHeights.map { Column.proportionHeight($0, g) }, current: frame.height, forwards: true))

        // Columns, tabs and the strip's view: nothing a floating window has.
        default: break
        }
        return true
    }

    func centered(_ size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
}
