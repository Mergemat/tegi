import AppKit
import TegiCore

extension WindowManager {
    func activeWorkspaceID(on m: Int? = nil) -> Int? {
        let m = m ?? world.focusedMonitor
        guard world.monitors.indices.contains(m) else { return nil }
        return world.monitors[m].workspaces[world.monitors[m].active].id
    }

    func floatTarget(_ rule: WindowRule) -> Int? {
        if let name = rule.workspace, let (m, w) = world.resolve(.name(name)) { return world.monitors[m].workspaces[w].id }
        return activeWorkspaceID()
    }

    func floatMonitor(_ win: Win) -> Int? { win.floatHome.flatMap { world.find(workspace: $0)?.monitor } }

    func floatersShowing(on m: Int) -> [WindowID] {
        guard let active = activeWorkspaceID(on: m) else { return [] }
        let ids = wins.values.filter { $0.floating && !$0.suspended && $0.floatHome == active }.map(\.id)
        return recent.ordered(ids)
    }

    func placeFloating() {
        for win in wins.values where win.floating && !win.suspended {
            if win.floatHome.flatMap({ world.find(workspace: $0) }) == nil { win.floatHome = activeWorkspaceID() }
            guard let home = win.floatHome, let (m, w) = world.find(workspace: home) else { continue }
            if world.monitors[m].active == w {
                if floatHidden.remove(win.id) != nil, let f = win.floatFrame { send(win.id, f) }
            } else if !floatHidden.contains(win.id) {
                floatHidden.insert(win.id)
                let size = win.floatFrame?.size ?? applied[win.id]?.size ?? CGSize(width: 600, height: 400)
                send(win.id, mode.hide(win, size: size, on: m))
            }
        }
    }

    func floatingMoved(_ win: Win) {
        win.worker.read(win.element) { [weak self] info in
            guard let self, let info, let frame = info.frame, wins[win.id] != nil, win.floating, !floatHidden.contains(win.id) else { return }
            win.floatFrame = frame
            applied[win.id] = frame
            if let m = monitor(containing: frame), let home = activeWorkspaceID(on: m), home != win.floatHome {
                win.floatHome = home
            }
            updateLiveFloating(win)
        }
    }

    func toggleFloating() {
        guard let id = focused, let win = wins[id], !win.suspended else { return }
        setFloating(win, !win.floating)
        relayout()
        if win.floating { focusWindow(id) } else { focusModel() }
    }

    func setFocusedFloating(_ floating: Bool) {
        guard let id = focused, let win = wins[id], !win.suspended, win.floating != floating else { return }
        toggleFloating()
    }

    func setFloating(_ win: Win, _ floating: Bool) {
        // A menu or popover can't be tiled, whatever asks.
        guard win.floating != floating, floating || !win.popup else { return }
        win.floating = floating
        if floating {
            let m = world.locate(win.id)?.monitor ?? world.focusedMonitor
            win.floatHome = activeWorkspaceID(on: m)
            if let frame = applied[win.id], targets[win.id]?.visible == true {
                win.floatFrame = frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.05)
            }
            world.remove(win.id, config: config)
            floatHidden.remove(win.id)
            if let f = win.floatFrame { send(win.id, f) }
        } else {
            win.floatHome = nil
            floatHidden.remove(win.id)
            applied[win.id] = nil
            if !win.suspended { world.insert(win.id, rule: rule(win), config: config) }
        }
    }

    func focusFloating() {
        if let id = floatersShowing(on: world.focusedMonitor).first { focusWindow(id) }
    }

    func runFloating(_ command: Command, _ win: Win) -> Bool {
        func move(toWorkspace target: (Int, Int)?) -> Bool {
            guard let (m, w) = target, let fromM = floatMonitor(win) else { return true }
            let id = world.monitors[m].workspaces[w].id
            if m != fromM, let f = win.floatFrame {
                let from = world.monitors[fromM].area, to = world.monitors[m].area
                win.floatFrame = f.offsetBy(dx: to.minX - from.minX, dy: to.minY - from.minY)
            }
            win.floatHome = id
            world.showWorkspace(monitor: m, index: w)
            if !floatHidden.contains(win.id), let f = win.floatFrame { send(win.id, f) }
            relayout()
            focusWindow(win.id)
            return true
        }
        let m = floatMonitor(win) ?? world.focusedMonitor
        let active = world.monitors.indices.contains(m) ? world.monitors[m].active : 0
        switch command {
        case .moveWindowToWorkspaceUp, .moveColumnToWorkspaceUp: return move(toWorkspace: (m, max(0, active - 1)))
        case .moveWindowToWorkspaceDown, .moveColumnToWorkspaceDown:
            return move(toWorkspace: (m, min(world.monitors[m].workspaces.count - 1, active + 1)))
        case .moveWindowToWorkspace(let ref), .moveColumnToWorkspace(let ref):
            world.focusedMonitor = m
            return move(toWorkspace: world.resolve(ref))
        case .moveWindowToMonitor(let d), .moveColumnToMonitor(let d):
            guard let target = world.monitor(from: m, d) else { return true }
            world.focusedMonitor = target
            return move(toWorkspace: (target, world.monitors[target].active))
        case .centerWindow, .centerColumn:
            guard let f = win.floatFrame, world.monitors.indices.contains(m) else { return true }
            let area = world.monitors[m].area
            win.floatFrame = CGRect(x: area.midX - f.width / 2, y: area.midY - f.height / 2, width: f.width, height: f.height).roundedToPoints
            send(win.id, win.floatFrame!)
            return true
        case .setColumnWidth(let change), .setWindowHeight(let change):
            guard var f = win.floatFrame, world.monitors.indices.contains(m) else { return true }
            let wide: Bool
            if case .setColumnWidth = command { wide = true } else { wide = false }
            let full = wide ? world.monitors[m].area.width : world.monitors[m].area.height
            let current = wide ? f.width : f.height
            let next: Double
            switch change {
            case .setFixed(let v): next = v
            case .adjustFixed(let d): next = current + d
            case .setProportion(let p): next = full * p
            case .adjustProportion(let d): next = current + full * d
            }
            if wide { f.size.width = max(100, min(next, full)) } else { f.size.height = max(60, min(next, full)) }
            win.floatFrame = f.roundedToPoints
            send(win.id, win.floatFrame!)
            return true
        default:
            return false
        }
    }
}

extension WindowManager {
    func openSwitcher(forward: Bool, sameApp: Bool) {
        if recent.isOpen { return recent.step(forward ? 1 : -1) }
        var ids = recent.ordered(wins.values.filter { !$0.suspended && !snapshots.blank.contains($0.id) }.map(\.id))
        if let current = focused, let i = ids.firstIndex(of: current) { ids.insert(ids.remove(at: i), at: 0) }
        if sameApp, let pid = focused.flatMap({ wins[$0] })?.worker.pid { ids = ids.filter { wins[$0]?.worker.pid == pid } }
        if config.switcherWindows != .everywhere {
            let monitor = world.focusedMonitor
            let workspace = world.monitors.indices.contains(monitor) ? world.monitors[monitor].active : nil
            ids = ids.filter { id in
                guard let place = self.place(id) else { return false }
                return place.monitor == monitor && (config.switcherWindows == .display || place.workspace == workspace)
            }
        }
        let icons = config.switcherShows == .icons
        let items = ids.compactMap { id -> RecentWindows.Item? in
            guard let win = wins[id] else { return nil }
            let size = applied[id]?.size ?? win.floatFrame?.size ?? CGSize(width: 800, height: 600)
            return RecentWindows.Item(id: id, title: win.title, app: win.worker.name, image: icons ? nil : snapshots.images[id],
                                      icon: win.worker.icon, size: size)
        }
        recent.open(items, forward: forward, config: config)
        guard !icons else { return }
        let list = ids.compactMap { id in wins[id].map { (id: id, windowID: $0.windowID) } }
        snapshots.refresh(list, scale: NSScreen.main?.backingScaleFactor ?? 2) { [weak self] id in
            guard let self, let image = snapshots.images[id] else { return }
            if snapshots.blank.contains(id) { return recent.drop(id) }
            recent.setImage(image, for: id)
        }
    }

    /// The display and workspace a window lives on, floating ones on their home workspace.
    private func place(_ id: WindowID) -> (monitor: Int, workspace: Int)? {
        if let home = wins[id]?.floatHome, wins[id]?.floating == true { return world.find(workspace: home).map { ($0.monitor, $0.index) } }
        return world.locate(id).map { ($0.monitor, $0.workspace) }
    }

    /// Like niri, windows that aren't tiled stay above the tiles: floating ones, and the ones tegi leaves alone, such
    /// as an app's onboarding panel. macOS raises a tile above them when it takes focus, so they go back on top.
    func keepFloatingOnTop() {
        guard mode.liveScenes else { return }
        let tiled = Set(wins.values.filter { !$0.fullScreen && !$0.suspended && $0.windowID != 0 }.map(\.windowID))
        let me = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let screens = world.monitors.map(\.screen)
        // Front to back.
        let windows = list.compactMap { w -> (id: CGWindowID, tiled: Bool, floats: Bool)? in
            guard w[kCGWindowLayer as String] as? Int == 0, let id = w[kCGWindowNumber as String] as? CGWindowID,
                  w[kCGWindowOwnerPID as String] as? pid_t != me,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: b) else { return nil }
            // Invisible and screen-sized windows would catch clicks meant for the tiles.
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let floats = alpha > 0 && frame.width >= 100 && frame.height >= 60 && !screens.contains { frame.contains($0) }
            return (id, tiled.contains(id), floats)
        }
        guard let top = windows.firstIndex(where: \.tiled),
              windows[(top + 1)...].contains(where: { !$0.tiled && $0.floats }) else { return }
        var above = windows[top].id
        for w in windows.reversed() where !w.tiled && w.floats {
            windowServer.raise(w.id, above: above)
            above = w.id
        }
    }

    /// After macOS raises a tile, which apps finish doing after tegi hears they took focus: the ring goes back under it
    /// and the windows that float back above it.
    func restack() {
        // Paused, tegi leaves the windows alone.
        guard !paused else { return }
        keepFloatingOnTop()
        ring.restack()
    }

    func watchWindowOrder() {
        WindowServer.watchOrder(of: wins.values.filter { !$0.floating && !$0.suspended && $0.windowID != 0 }.map(\.windowID))
    }
}
