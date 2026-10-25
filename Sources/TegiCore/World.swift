import CoreGraphics

public struct Display: Equatable {
    public var id: UInt32
    public var name: String
    public var screen: CGRect
    public var area: CGRect

    public init(id: UInt32, name: String = "", screen: CGRect, area: CGRect) {
        self.id = id
        self.name = name
        self.screen = screen
        self.area = area
    }
}

public struct Monitor: Equatable {
    public let id: UInt32
    public var name = ""
    public var screen: CGRect
    public var area: CGRect
    public var workspaces: [Workspace] = []
    public var active = 0
    public var previousWorkspace: Int?

    public init(id: UInt32, screen: CGRect, area: CGRect) {
        self.id = id
        self.screen = screen
        self.area = area
    }
}

public enum InsertPosition: Equatable {
    case newColumn(Int)
    case inColumn(Int, tile: Int)
}

public struct Placement: Equatable {
    public var frame: CGRect
    public var visible: Bool
    public var strip: CGRect?
    public var monitor: Int
}

public struct World: Equatable {
    public var monitors: [Monitor]
    public var focusedMonitor = 0
    public var emptyWorkspaceAboveFirst = false
    public var pinned: Set<Int> = []
    private var nextWorkspaceID = 1

    public init(monitors: [Monitor]) {
        self.monitors = monitors
        for m in self.monitors.indices { normalize(m) }
    }

    public var focusedWindow: WindowID? {
        guard monitors.indices.contains(focusedMonitor) else { return nil }
        let mon = monitors[focusedMonitor]
        return mon.workspaces[mon.active].activeWindow
    }

    public func locate(_ id: WindowID) -> (monitor: Int, workspace: Int, column: Int, tile: Int)? {
        for (m, mon) in monitors.enumerated() {
            for (w, ws) in mon.workspaces.enumerated() {
                if let (c, t) = ws.column(of: id) { return (m, w, c, t) }
            }
        }
        return nil
    }

    private func geometry(_ m: Int, _ config: Config) -> Geometry { Geometry(area: monitors[m].area, config: config) }

    private mutating func newWorkspace(home: UInt32) -> Workspace {
        defer { nextWorkspaceID += 1 }
        return Workspace(id: nextWorkspaceID, home: home)
    }

    private mutating func withActive<T>(_ m: Int, _ config: Config, _ body: (inout Workspace, Geometry) -> T) -> T {
        let g = geometry(m, config)
        let a = monitors[m].active
        return body(&monitors[m].workspaces[a], g)
    }

    private mutating func activateWorkspace(_ m: Int, _ idx: Int) {
        let idx = max(0, min(monitors[m].workspaces.count - 1, idx))
        guard idx != monitors[m].active else { return }
        monitors[m].previousWorkspace = monitors[m].workspaces[monitors[m].active].id
        monitors[m].active = idx
    }

    mutating func normalize(_ m: Int) {
        func disposable(_ ws: Workspace) -> Bool { ws.isEmpty && ws.name == nil && !pinned.contains(ws.id) }
        let last = monitors[m].workspaces.last
        if last == nil || !disposable(last!) {
            monitors[m].workspaces.append(newWorkspace(home: monitors[m].id))
        }
        if emptyWorkspaceAboveFirst, let first = monitors[m].workspaces.first, !disposable(first) {
            monitors[m].workspaces.insert(newWorkspace(home: monitors[m].id), at: 0)
            monitors[m].active += 1
        }
        let keepFirst = emptyWorkspaceAboveFirst ? 1 : 0
        for i in stride(from: monitors[m].workspaces.count - 2, through: keepFirst, by: -1)
        where i != monitors[m].active && disposable(monitors[m].workspaces[i]) {
            monitors[m].workspaces.remove(at: i)
            if monitors[m].active > i { monitors[m].active -= 1 }
        }
    }

    public mutating func insert(_ id: WindowID, monitor m: Int? = nil, rule: WindowRule = WindowRule(), config: Config) {
        var m = m ?? focusedMonitor
        if let name = rule.display, let d = monitors.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(name) }) { m = d }
        guard monitors.indices.contains(m) else { return }
        var w = monitors[m].active
        if let name = rule.workspace, let (wm, wi) = resolve(.name(name)) { (m, w) = (wm, wi) }
        let g = geometry(m, config)
        let shown = w == monitors[m].active
        var column = Column(id, width: .proportion(rule.width ?? config.defaultColumnWidth), fullWidth: rule.maximized == true)
        column.tabbed = config.defaultColumnDisplayTabbed
        if monitors[m].workspaces[w].name == nil { monitors[m].workspaces[w].home = monitors[m].id }
        let ws = monitors[m].workspaces[w]
        let at = switch config.newWindowPosition {
        case .right: ws.active + 1
        case .left: ws.active
        case .start: 0
        case .end: ws.columns.count
        }
        monitors[m].workspaces[w].addColumn(column, at: ws.isEmpty ? 0 : at, activate: ws.isEmpty || shown && rule.focused != false, g)
        normalize(m)
    }

    public func find(workspace id: Int) -> (monitor: Int, index: Int)? {
        for (m, mon) in monitors.enumerated() {
            if let w = mon.workspaces.firstIndex(where: { $0.id == id }) { return (m, w) }
        }
        return nil
    }

    public func resolve(_ ref: WorkspaceRef) -> (monitor: Int, index: Int)? {
        switch ref {
        case .index(let n):
            guard monitors.indices.contains(focusedMonitor) else { return nil }
            return (focusedMonitor, max(0, min(n - 1, monitors[focusedMonitor].workspaces.count - 1)))
        case .name(let name):
            for (m, mon) in monitors.enumerated() {
                if let w = mon.workspaces.firstIndex(where: { $0.name == name }) { return (m, w) }
            }
            return nil
        }
    }

    public mutating func nameWorkspaces(_ named: [NamedWorkspace]) {
        for n in named where resolve(.name(n.name)) == nil {
            let m = n.display.flatMap { d in monitors.firstIndex { $0.name.localizedCaseInsensitiveContains(d) } } ?? 0
            guard monitors.indices.contains(m) else { continue }
            var ws = newWorkspace(home: monitors[m].id)
            ws.name = n.name
            let at = monitors[m].workspaces.prefix { $0.name != nil }.count
            monitors[m].workspaces.insert(ws, at: at)
            if at <= monitors[m].active { monitors[m].active += 1 }
            normalize(m)
        }
    }

    public mutating func adopt(_ id: WindowID, monitor m: Int? = nil, config: Config) {
        let m = m ?? focusedMonitor
        guard monitors.indices.contains(m) else { return }
        withActive(m, config) { ws, g in
            ws.addColumn(Column(id, width: .proportion(config.defaultColumnWidth)), at: ws.columns.count, activate: ws.isEmpty, g)
        }
        normalize(m)
    }

    public mutating func remove(_ id: WindowID, config: Config) {
        guard let (m, w, c, t) = locate(id) else { return }
        _ = monitors[m].workspaces[w].removeTile(c, t, geometry(m, config))
        normalize(m)
    }

    public mutating func focus(_ id: WindowID, config: Config) {
        guard let (m, w, c, t) = locate(id) else { return }
        focusedMonitor = m
        activateWorkspace(m, w)
        withActive(m, config) { ws, g in
            ws.columns[c].active = t
            ws.activate(c, g)
        }
        normalize(m)
    }

    public mutating func moveWindow(_ id: WindowID, toMonitor target: Int, config: Config) {
        guard monitors.indices.contains(target), let (m, w, c, t) = locate(id), m != target else { return }
        let removed = monitors[m].workspaces[w].removeTile(c, t, geometry(m, config))
        normalize(m)
        addColumn(Column(removed.tile.id, width: removed.width, fullWidth: removed.fullWidth), to: target, config)
        focusedMonitor = target
    }

    public mutating func move(_ id: WindowID, to m: Int, workspace w: Int, at position: InsertPosition, config: Config) {
        guard let from = locate(id), monitors.indices.contains(m), monitors[m].workspaces.indices.contains(w) else { return }
        let targetID = monitors[m].workspaces[w].id
        let sameWorkspace = from.monitor == m && from.workspace == w
        let columnGoes = monitors[from.monitor].workspaces[from.workspace].columns[from.column].tiles.count == 1
        var position = position
        if sameWorkspace && columnGoes, case .inColumn(from.column, _) = position { return }
        if sameWorkspace {
            switch position {
            case .newColumn(let c) where columnGoes && from.column < c:
                position = .newColumn(c - 1)
            case .inColumn(let c, let t):
                if columnGoes && from.column < c {
                    position = .inColumn(c - 1, tile: t)
                } else if from.column == c && from.tile < t {
                    position = .inColumn(c, tile: t - 1)
                }
            default:
                break
            }
            if columnGoes, case .newColumn(from.column) = position { return }
        }
        let removed = monitors[from.monitor].workspaces[from.workspace].removeTile(from.column, from.tile, geometry(from.monitor, config))
        guard let (tm, tw) = find(workspace: targetID) else { return }
        let g = geometry(tm, config)
        switch position {
        case .newColumn(let c):
            let at = max(0, min(c, monitors[tm].workspaces[tw].columns.count))
            monitors[tm].workspaces[tw].addColumn(Column(id, width: removed.width, fullWidth: removed.fullWidth), at: at, activate: true, g)
        case .inColumn(let c, let t):
            var ws = monitors[tm].workspaces[tw]
            guard ws.columns.indices.contains(c) else {
                monitors[tm].workspaces[tw].addColumn(Column(id, width: removed.width), activate: true, g)
                break
            }
            ws.columns[c].tiles.insert(Tile(id: id), at: max(0, min(t, ws.columns[c].tiles.count)))
            ws.columns[c].active = max(0, min(t, ws.columns[c].tiles.count - 1))
            ws.activate(c, g)
            monitors[tm].workspaces[tw] = ws
        }
        focusedMonitor = tm
        activateWorkspace(tm, tw)
        for i in monitors.indices { normalize(i) }
    }

    public func insertPosition(monitor m: Int, workspace w: Int, at point: CGPoint, config: Config) -> InsertPosition {
        guard monitors.indices.contains(m), monitors[m].workspaces.indices.contains(w) else { return .newColumn(0) }
        let frames = stripFrames(monitor: m, workspace: w, config: config)
        let ws = monitors[m].workspaces[w]
        guard !ws.columns.isEmpty else { return .newColumn(0) }
        let gap = config.gap
        var edges: [Double] = []
        var columnBox: [(minX: Double, maxX: Double)] = []
        for col in ws.columns {
            let xs: [CGRect] = frames.filter { f in col.windows.contains(f.id) }.map { $0.frame }
            let minX: Double = xs.map { Double($0.minX) }.min() ?? 0
            let maxX: Double = xs.map { Double($0.maxX) }.max() ?? 0
            columnBox.append((minX, maxX))
        }
        for (i, box) in columnBox.enumerated() { edges.append(i == 0 ? box.minX - gap / 2 : (columnBox[i - 1].maxX + box.minX) / 2) }
        edges.append(columnBox.last!.maxX + gap / 2)
        let px = Double(point.x), py = Double(point.y)
        let nearestEdge = edges.indices.min { abs(edges[$0] - px) < abs(edges[$1] - px) }!
        guard let c = columnBox.firstIndex(where: { px >= $0.minX && px <= $0.maxX }), !ws.columns[c].tabbed else {
            return .newColumn(nearestEdge)
        }
        let tiles: [CGRect] = ws.columns[c].windows.compactMap { id in frames.first { $0.id == id }?.frame }
        var rows: [Double] = tiles.map { Double($0.minY) }
        rows.append(Double(tiles.last?.maxY ?? 0))
        let nearestRow = rows.indices.min { abs(rows[$0] - py) < abs(rows[$1] - py) }!
        return abs(rows[nearestRow] - py) < abs(edges[nearestEdge] - px) ? .inColumn(c, tile: nearestRow) : .newColumn(nearestEdge)
    }

    public mutating func moveToNewWorkspace(_ id: WindowID, monitor m: Int, at index: Int, config: Config) {
        guard monitors.indices.contains(m), locate(id) != nil else { return }
        let at = max(0, min(index, monitors[m].workspaces.count))
        let ws = newWorkspace(home: monitors[m].id)
        monitors[m].workspaces.insert(ws, at: at)
        if at <= monitors[m].active { monitors[m].active += 1 }
        if let previous = monitors[m].previousWorkspace, previous == ws.id { monitors[m].previousWorkspace = nil }
        guard let (tm, tw) = find(workspace: ws.id) else { return }
        move(id, to: tm, workspace: tw, at: .newColumn(0), config: config)
    }

    public mutating func adoptWidth(_ px: Double, for id: WindowID, config: Config) {
        guard let (m, w, c, _) = locate(id) else { return }
        let g = geometry(m, config)
        monitors[m].workspaces[w].columns[c].width = .fixed(px)
        monitors[m].workspaces[w].columns[c].presetWidth = nil
        monitors[m].workspaces[w].columns[c].fullWidth = false
        if monitors[m].workspaces[w].active == c { monitors[m].workspaces[w].refit(g) }
    }

    public mutating func setDisplays(_ displays: [Display], config: Config) {
        guard !displays.isEmpty else { return }
        let old = monitors
        let focusedID = old.indices.contains(focusedMonitor) ? old[focusedMonitor].id : nil
        monitors = displays.map { d in
            var mon = old.first { $0.id == d.id } ?? Monitor(id: d.id, screen: d.screen, area: d.area)
            mon.name = d.name
            mon.screen = d.screen
            mon.area = d.area
            return mon
        }
        for m in monitors.indices { normalize(m) }

        for m in monitors.indices {
            let returning = monitors.indices.filter { $0 != m }.flatMap { o in
                monitors[o].workspaces.filter { $0.home == monitors[m].id && !$0.isEmpty }
            }
            guard !returning.isEmpty else { continue }
            let home = monitors[m].id
            for o in monitors.indices where o != m {
                let activeID = monitors[o].workspaces[monitors[o].active].id
                monitors[o].workspaces.removeAll { $0.home == home && !$0.isEmpty }
                monitors[o].active = monitors[o].workspaces.firstIndex { $0.id == activeID } ?? 0
                normalize(o)
            }
            append(returning, to: m)
        }
        for orphan in old where !displays.contains(where: { $0.id == orphan.id }) {
            append(orphan.workspaces.filter { !$0.isEmpty }, to: 0)
        }
        focusedMonitor = monitors.firstIndex { $0.id == focusedID } ?? 0
        for m in monitors.indices {
            withActive(m, config) { ws, g in ws.refit(g) }
            normalize(m)
        }
    }

    private mutating func append(_ workspaces: [Workspace], to m: Int) {
        guard !workspaces.isEmpty else { return }
        let emptyWasActive = monitors[m].active == monitors[m].workspaces.count - 1
        monitors[m].workspaces.insert(contentsOf: workspaces, at: monitors[m].workspaces.count - 1)
        if emptyWasActive { monitors[m].active = monitors[m].workspaces.count - 1 }
        normalize(m)
    }

    private mutating func addColumn(_ column: Column, to m: Int, _ config: Config) {
        let home = monitors[m].id
        withActive(m, config) { ws, g in
            ws.home = home
            ws.addColumn(column, activate: true, g)
        }
        normalize(m)
    }

    public func stripFrames(monitor m: Int, workspace w: Int, config: Config) -> [(id: WindowID, frame: CGRect, active: Bool)] {
        guard monitors.indices.contains(m), monitors[m].workspaces.indices.contains(w) else { return [] }
        let g = geometry(m, config)
        let ws = monitors[m].workspaces[w]
        let view = ws.viewPos(g)
        var out: [(WindowID, CGRect, Bool)] = []
        var x = 0.0
        for (c, col) in ws.columns.enumerated() {
            let width = col.resolvedWidth(g)
            let heights = col.tileHeights(g)
            var y = col.fullscreen ? 0 : g.gap
            for (t, tile) in col.tiles.enumerated() {
                if !col.tabbed || t == col.active {
                    out.append((tile.id, CGRect(x: (x - view).rounded(), y: y.rounded(), width: width, height: heights[t]),
                                c == ws.active && t == col.active))
                }
                if !col.tabbed { y += heights[t] + g.gap }
            }
            x += width + g.gap
        }
        return out
    }

    public mutating func showWorkspace(monitor m: Int, index: Int) {
        guard monitors.indices.contains(m) else { return }
        focusedMonitor = m
        activateWorkspace(m, index)
        normalize(m)
    }

    public func viewPosition(monitor m: Int, config: Config) -> Double {
        guard monitors.indices.contains(m) else { return 0 }
        return monitors[m].workspaces[monitors[m].active].viewPos(geometry(m, config))
    }

    public mutating func scrollView(monitor m: Int, by dx: Double, config: Config) {
        guard monitors.indices.contains(m) else { return }
        withActive(m, config) { ws, _ in ws.scroll(by: dx) }
    }

    public mutating func edgeScroll(monitor m: Int, by dx: Double, config: Config) {
        guard monitors.indices.contains(m) else { return }
        withActive(m, config) { ws, g in ws.scrollWithinEnds(by: dx, g) }
    }

    public mutating func endSwipe(monitor m: Int, coastingTo target: Double, config: Config) {
        guard monitors.indices.contains(m) else { return }
        focusedMonitor = m
        withActive(m, config) { ws, g in ws.endSwipe(coastingTo: target, g) }
    }

    public mutating func perform(_ command: Command, config: Config) {
        let m = focusedMonitor
        guard monitors.indices.contains(m) else { return }
        let a = monitors[m].active

        switch command {
        case .focusColumnLeft: withActive(m, config) { ws, g in ws.focusColumn(ws.active - 1, g) }
        case .focusColumnRight: withActive(m, config) { ws, g in ws.focusColumn(ws.active + 1, g) }
        case .focusColumnFirst: withActive(m, config) { ws, g in ws.focusColumn(0, g) }
        case .focusColumnLast: withActive(m, config) { ws, g in ws.focusColumn(ws.columns.count - 1, g) }
        case .focusColumn(let n): withActive(m, config) { ws, g in ws.focusColumn(n - 1, g) }
        case .focusColumnRightOrFirst:
            withActive(m, config) { ws, g in ws.focusColumn(ws.active + 1 < ws.columns.count ? ws.active + 1 : 0, g) }
        case .focusColumnLeftOrLast:
            withActive(m, config) { ws, g in ws.focusColumn(ws.active > 0 ? ws.active - 1 : ws.columns.count - 1, g) }
        case .focusWindowTop: withActive(m, config) { ws, _ in ws.focusTile(at: 0) }
        case .focusWindowBottom: withActive(m, config) { ws, _ in ws.focusTile(at: .max) }
        case .focusWindowInColumn(let n): withActive(m, config) { ws, _ in ws.focusTile(at: n - 1) }
        case .focusWindowDownOrTop:
            withActive(m, config) { ws, _ in if !ws.focusTile(by: 1) { ws.focusTile(at: 0) } }
        case .focusWindowUpOrBottom:
            withActive(m, config) { ws, _ in if !ws.focusTile(by: -1) { ws.focusTile(at: .max) } }
        case .focusWindowDownOrColumnLeft, .focusWindowDownOrColumnRight, .focusWindowUpOrColumnLeft, .focusWindowUpOrColumnRight:
            let down = command == .focusWindowDownOrColumnLeft || command == .focusWindowDownOrColumnRight
            let left = command == .focusWindowDownOrColumnLeft || command == .focusWindowUpOrColumnLeft
            withActive(m, config) { ws, g in if !ws.focusTile(by: down ? 1 : -1) { ws.focusColumn(ws.active + (left ? -1 : 1), g) } }
        case .focusWindowOrMonitorUp:
            if !withActive(m, config, { ws, _ in ws.focusTile(by: -1) }) { focusMonitor(.up) }
        case .focusWindowOrMonitorDown:
            if !withActive(m, config, { ws, _ in ws.focusTile(by: 1) }) { focusMonitor(.down) }
        case .focusColumnOrMonitorLeft, .focusColumnOrMonitorRight:
            let left = command == .focusColumnOrMonitorLeft
            let moved = withActive(m, config) { ws, g -> Bool in
                let target = ws.active + (left ? -1 : 1)
                guard ws.columns.indices.contains(target) else { return false }
                ws.focusColumn(target, g)
                return true
            }
            if !moved { focusMonitor(left ? .left : .right) }

        case .focusWindowUp: _ = withActive(m, config) { ws, _ in ws.focusTile(by: -1) }
        case .focusWindowDown: _ = withActive(m, config) { ws, _ in ws.focusTile(by: 1) }
        case .focusWindowOrWorkspaceUp:
            if !withActive(m, config, { ws, _ in ws.focusTile(by: -1) }) { activateWorkspace(m, a - 1) }
        case .focusWindowOrWorkspaceDown:
            if !withActive(m, config, { ws, _ in ws.focusTile(by: 1) }) { activateWorkspace(m, a + 1) }

        case .focusWorkspaceUp: activateWorkspace(m, a - 1)
        case .focusWorkspaceDown: activateWorkspace(m, a + 1)
        case .focusWorkspace(let ref):
            guard let (tm, idx) = resolve(ref) else { break }
            if tm == m && idx == a && config.workspaceAutoBackAndForth {
                focusPreviousWorkspace(m)
            } else {
                focusedMonitor = tm
                activateWorkspace(tm, idx)
            }
        case .focusWorkspacePrevious: focusPreviousWorkspace(m)

        case .moveColumnLeft: withActive(m, config) { ws, g in ws.moveColumn(to: ws.active - 1, g) }
        case .moveColumnRight: withActive(m, config) { ws, g in ws.moveColumn(to: ws.active + 1, g) }
        case .moveColumnToFirst: withActive(m, config) { ws, g in ws.moveColumn(to: 0, g) }
        case .moveColumnToLast: withActive(m, config) { ws, g in ws.moveColumn(to: ws.columns.count - 1, g) }
        case .moveColumnToIndex(let n): withActive(m, config) { ws, g in ws.moveColumn(to: min(n - 1, ws.columns.count - 1), g) }
        case .swapWindowLeft: withActive(m, config) { ws, g in ws.swapWindow(left: true, g) }
        case .swapWindowRight: withActive(m, config) { ws, g in ws.swapWindow(left: false, g) }
        case .moveColumnLeftOrToMonitorLeft, .moveColumnRightOrToMonitorRight:
            let left = command == .moveColumnLeftOrToMonitorLeft
            let moved = withActive(m, config) { ws, g -> Bool in
                let target = ws.active + (left ? -1 : 1)
                guard ws.columns.indices.contains(target) else { return false }
                ws.moveColumn(to: target, g)
                return true
            }
            if !moved { moveColumn(toMonitor: left ? .left : .right, config) }

        case .moveWindowUp: _ = withActive(m, config) { ws, _ in ws.moveTile(by: -1) }
        case .moveWindowDown: _ = withActive(m, config) { ws, _ in ws.moveTile(by: 1) }
        case .moveWindowUpOrToWorkspaceUp:
            if !withActive(m, config, { ws, _ in ws.moveTile(by: -1) }) { moveWindow(toWorkspace: a - 1, config) }
        case .moveWindowDownOrToWorkspaceDown:
            if !withActive(m, config, { ws, _ in ws.moveTile(by: 1) }) { moveWindow(toWorkspace: a + 1, config) }

        case .moveColumnToWorkspaceUp: moveColumn(toWorkspace: a - 1, config)
        case .moveColumnToWorkspaceDown: moveColumn(toWorkspace: a + 1, config)
        case .moveColumnToWorkspace(let ref):
            if let (tm, idx) = resolve(ref) { moveColumn(toWorkspace: idx, on: tm, config) }
        case .moveWindowToWorkspaceUp: moveWindow(toWorkspace: a - 1, config)
        case .moveWindowToWorkspaceDown: moveWindow(toWorkspace: a + 1, config)
        case .moveWindowToWorkspace(let ref):
            if let (tm, idx) = resolve(ref) { moveWindow(toWorkspace: idx, on: tm, config) }

        case .moveWorkspaceUp, .moveWorkspaceDown:
            let target = a + (command == .moveWorkspaceUp ? -1 : 1)
            guard monitors[m].workspaces.indices.contains(target) else { break }
            monitors[m].workspaces.swapAt(a, target)
            monitors[m].active = target
        case .moveWorkspaceToIndex(let n):
            let target = max(0, min(n - 1, monitors[m].workspaces.count - 1))
            monitors[m].workspaces.insert(monitors[m].workspaces.remove(at: a), at: target)
            monitors[m].active = target
        case .setWorkspaceName(let name):
            for (om, mon) in monitors.enumerated() {
                for (ow, ws) in mon.workspaces.enumerated() where ws.name == name { monitors[om].workspaces[ow].name = nil }
            }
            monitors[m].workspaces[a].name = name
        case .unsetWorkspaceName:
            monitors[m].workspaces[a].name = nil

        case .focusMonitor(let d): focusMonitor(d)
        case .moveColumnToMonitor(let d): moveColumn(toMonitor: d, config)
        case .moveWindowToMonitor(let d):
            if let id = focusedWindow, let target = monitor(from: m, d) { moveWindow(id, toMonitor: target, config: config) }
        case .moveWorkspaceToMonitor(let d):
            guard let target = monitor(from: m, d), !monitors[m].workspaces[a].isEmpty else { break }
            var ws = monitors[m].workspaces.remove(at: a)
            monitors[m].active = min(a, monitors[m].workspaces.count - 1)
            normalize(m)
            ws.home = monitors[target].id
            let at = monitors[target].active + 1
            monitors[target].workspaces.insert(ws, at: min(at, monitors[target].workspaces.count))
            activateWorkspace(target, min(at, monitors[target].workspaces.count - 1))
            focusedMonitor = target
            withActive(target, config) { ws, g in ws.refit(g) }
            normalize(target)

        case .consumeWindowIntoColumn: withActive(m, config) { ws, g in ws.consumeIntoColumn(g) }
        case .expelWindowFromColumn: withActive(m, config) { ws, g in ws.expelFromColumn(g) }
        case .consumeOrExpelWindowLeft: withActive(m, config) { ws, g in ws.consumeOrExpel(left: true, g) }
        case .consumeOrExpelWindowRight: withActive(m, config) { ws, g in ws.consumeOrExpel(left: false, g) }
        case .switchPresetColumnWidth: withActive(m, config) { ws, g in ws.cycleWidth(forwards: true, g) }
        case .switchPresetColumnWidthBack: withActive(m, config) { ws, g in ws.cycleWidth(forwards: false, g) }
        case .switchPresetWindowHeight: withActive(m, config) { ws, g in ws.cycleHeight(g) }
        case .resetWindowHeight: withActive(m, config) { ws, _ in ws.resetHeight() }
        case .setColumnWidth(let c): withActive(m, config) { ws, g in ws.setWidth(c, g) }
        case .setWindowHeight(let c): withActive(m, config) { ws, g in ws.setHeight(c, g) }
        case .maximizeColumn: withActive(m, config) { ws, g in ws.toggleFullWidth(g) }
        case .expandColumnToAvailableWidth: withActive(m, config) { ws, g in ws.expandToAvailableWidth(g) }
        case .fullscreenWindow, .maximizeWindowToEdges: withActive(m, config) { ws, g in ws.toggleFullscreen(g) }
        case .toggleColumnTabbedDisplay: withActive(m, config) { ws, _ in ws.toggleTabbed() }
        case .setColumnDisplay(let tabbed): withActive(m, config) { ws, _ in ws.setTabbed(tabbed) }
        case .centerColumn, .centerWindow: withActive(m, config) { ws, g in ws.center(g) }
        case .centerVisibleColumns: withActive(m, config) { ws, g in ws.centerVisibleColumns(g) }
        default: break
        }
        for i in monitors.indices { normalize(i) }
    }

    private mutating func focusPreviousWorkspace(_ m: Int) {
        guard let id = monitors[m].previousWorkspace,
              let idx = monitors[m].workspaces.firstIndex(where: { $0.id == id }) else { return }
        activateWorkspace(m, idx)
    }

    private mutating func moveColumn(toWorkspace target: Int, on tm: Int? = nil, _ config: Config) {
        let m = focusedMonitor, a = monitors[m].active, tm = tm ?? m
        let target = max(0, min(monitors[tm].workspaces.count - 1, target))
        guard tm != m || target != a, monitors[m].workspaces[a].columns.indices.contains(monitors[m].workspaces[a].active) else { return }
        let col = monitors[m].workspaces[a].removeColumn(monitors[m].workspaces[a].active, geometry(m, config))
        monitors[tm].workspaces[target].addColumn(col, activate: true, geometry(tm, config))
        focusedMonitor = tm
        activateWorkspace(tm, target)
        if tm != m { normalize(m) }
    }

    private mutating func moveWindow(toWorkspace target: Int, on tm: Int? = nil, _ config: Config) {
        let m = focusedMonitor, a = monitors[m].active, tm = tm ?? m
        let target = max(0, min(monitors[tm].workspaces.count - 1, target))
        let ws = monitors[m].workspaces[a]
        guard tm != m || target != a, ws.columns.indices.contains(ws.active) else { return }
        let removed = monitors[m].workspaces[a].removeTile(ws.active, ws.columns[ws.active].active, geometry(m, config))
        monitors[tm].workspaces[target].addColumn(
            Column(removed.tile.id, width: removed.width, fullWidth: removed.fullWidth), activate: true, geometry(tm, config))
        focusedMonitor = tm
        activateWorkspace(tm, target)
        if tm != m { normalize(m) }
    }

    private mutating func moveColumn(toMonitor d: Direction, _ config: Config) {
        let m = focusedMonitor, a = monitors[m].active
        let ws = monitors[m].workspaces[a]
        guard let target = monitor(from: m, d), ws.columns.indices.contains(ws.active) else { return }
        let col = monitors[m].workspaces[a].removeColumn(ws.active, geometry(m, config))
        normalize(m)
        addColumn(col, to: target, config)
        focusedMonitor = target
    }

    private mutating func focusMonitor(_ d: Direction) {
        if let target = monitor(from: focusedMonitor, d) { focusedMonitor = target }
    }

    public func monitor(from m: Int, _ d: Direction) -> Int? {
        guard monitors.indices.contains(m) else { return nil }
        let s = monitors[m].screen
        if d == .next || d == .previous {
            let order = monitors.indices.sorted {
                let a = monitors[$0].screen, b = monitors[$1].screen
                return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
            }
            guard order.count > 1, let i = order.firstIndex(of: m) else { return nil }
            return order[(i + (d == .next ? 1 : order.count - 1)) % order.count]
        }
        return monitors.indices.filter { $0 != m }.filter { o in
            let r = monitors[o].screen
            switch d {
            case .left: return r.midX < s.midX && r.minY < s.maxY && r.maxY > s.minY
            case .right: return r.midX > s.midX && r.minY < s.maxY && r.maxY > s.minY
            case .up: return r.midY < s.midY && r.minX < s.maxX && r.maxX > s.minX
            case .down: return r.midY > s.midY && r.minX < s.maxX && r.maxX > s.minX
            case .next, .previous: return false
            }
        }.min { a, b in
            let ra = monitors[a].screen, rb = monitors[b].screen
            return d == .left || d == .right ? abs(ra.midX - s.midX) < abs(rb.midX - s.midX)
                : abs(ra.midY - s.midY) < abs(rb.midY - s.midY)
        }
    }

    public func layout(config: Config) -> [WindowID: Placement] {
        var out: [WindowID: Placement] = [:]
        for (mi, mon) in monitors.enumerated() {
            let others = monitors.enumerated().filter { $0.offset != mi }.map(\.element.screen)
            let g = Geometry(area: mon.area, config: config)
            for (wi, ws) in mon.workspaces.enumerated() {
                let view = ws.viewPos(g)
                var x = 0.0
                for col in ws.columns {
                    let w = col.resolvedWidth(g)
                    let heights = col.tileHeights(g)
                    var y = mon.area.minY + (col.fullscreen ? 0 : g.gap)
                    for (t, tile) in col.tiles.enumerated() {
                        let frame = CGRect(x: (mon.area.minX + x - view).rounded(), y: y.rounded(), width: w, height: heights[t])
                        if !col.tabbed { y += heights[t] + g.gap }
                        if wi == mon.active && (!col.tabbed || t == col.active) {
                            out[tile.id] = place(frame, on: mi)
                        } else {
                            out[tile.id] = Placement(frame: park(frame.size, area: mon.area, others: others), visible: false, monitor: mi)
                        }
                    }
                    x += w + g.gap
                }
            }
        }
        return out
    }

    public func place(_ frame: CGRect, on m: Int) -> Placement {
        let mon = monitors[m]
        let others = monitors.indices.filter { $0 != m }.map { monitors[$0].screen }
        let visible = frame.intersects(mon.screen) && !others.contains { $0.intersects(frame) }
        return Placement(frame: visible ? frame : park(frame.size, area: mon.area, others: others),
                         visible: visible, strip: frame, monitor: m)
    }

    // macOS won't move a window fully off screen; one point stays visible.
    func park(_ size: CGSize, area: CGRect, others: [CGRect]) -> CGRect {
        let right = CGRect(origin: CGPoint(x: area.maxX - 1, y: area.maxY - 1), size: size)
        if !others.contains(where: { $0.intersects(right) }) { return right }
        return CGRect(origin: CGPoint(x: area.minX - size.width + 1, y: area.maxY - 1), size: size)
    }
}
