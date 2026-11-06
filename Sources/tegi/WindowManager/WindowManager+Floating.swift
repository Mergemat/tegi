import AppKit
import TegiCore

extension WindowManager {
    func activeWorkspaceID(on m: Int? = nil) -> Int? {
        let m = m ?? world.focusedMonitor
        guard world.monitors.indices.contains(m) else { return nil }
        return world.monitors[m].workspaces[world.monitors[m].active].id
    }

    /// Floating windows on the workspaces showing, top first: they're above the strip, and the top one above the rest.
    func floatersShowing() -> [WindowID] {
        world.monitors.flatMap { $0.workspaces[$0.active].floaters.reversed().map(\.id) }
    }

    /// Its app or the user moved a floating window: that's where it floats now.
    func floatingMoved(_ win: Win, mouseDown: Bool) {
        // tegi's own moves echo back, every frame of a flight.
        guard mouseDown || !motion.isFlying(win.id) && !unlanded.contains(win.id) else { return }
        win.worker.read(win.element) { [weak self] info in
            guard let self, let frame = info?.frame, wins[win.id] === win, win.floating, targets[win.id]?.visible == true else { return }
            updateLiveFloating(win, frame)
            if mouseDown { return dragged[win.id] = frame }
            adoptFloatingFrame(win.id, frame)
            relayout()
        }
    }

    func adoptFloatingFrame(_ id: WindowID, _ frame: CGRect) {
        world.setFloatingFrame(id, frame)
        applied[id] = frame
        motion.stop(id, at: world.locateFloater(id).map { (frame, $0.monitor) })
    }

    func toggleFloating() {
        guard let id = focused, let win = wins[id], !win.suspended else { return }
        setFloating(win, !win.floating)
        focusWindow(id)
    }

    func setFocusedFloating(_ floating: Bool) {
        guard let id = focused, let win = wins[id], !win.suspended, win.floating != floating else { return }
        toggleFloating()
    }

    func setFloating(_ win: Win, _ floating: Bool) {
        // A menu or popover can't be tiled, whatever asks.
        guard win.floating != floating, floating || !win.popup else { return }
        win.floating = floating
        guard !win.suspended else { return }
        if floating {
            world.float(win.id, rule: rule(win), config: config)
        } else {
            applied[win.id] = nil
            world.tile(win.id, rule: rule(win), config: config)
        }
    }

    func focusLayer(floating: Bool?) {
        world.focusLayer(floating: floating)
        focusModel()
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
            let size = applied[id]?.size ?? targets[id]?.frame.size ?? CGSize(width: 800, height: 600)
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

    /// The display and workspace a window lives on.
    private func place(_ id: WindowID) -> (monitor: Int, workspace: Int)? {
        world.locate(id).map { ($0.monitor, $0.workspace) } ?? world.locateFloater(id).map { ($0.monitor, $0.workspace) }
    }

    /// After macOS raises a tile, which apps finish doing after tegi hears they took focus: the ring goes back under it.
    func restack() {
        // Paused, tegi leaves the windows alone.
        guard !paused else { return }
        ring.restack()
    }

    func watchWindowOrder() {
        let tiled = Set(wins.values.filter { !$0.floating && !$0.suspended && $0.windowID != 0 }.map(\.windowID))
        WindowServer.watchOrder(of: Array(tiled.union(windowServer.controlledIDs)))
    }
}
