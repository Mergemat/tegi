import AppKit
import QuartzCore
import TegiCore

extension WindowManager {
    func startScenes() {
        snapshots.refreshAccess(prompt: false)
        refreshWallpapers()
        rebuildScenes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            refreshSnapshots(Array(wins.keys))
        }
        // Pictures, not streams: any stream puts the screen-sharing indicator in the menu bar.
        freshener = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !paused, !motion.isMoving else { return }
            freshTicks += 1
            if overview {
                refreshSnapshots(world.monitors.indices.flatMap { m in self.sceneContent(m).flatMap { $0.map(\.id) } })
                return
            }
            let anyInput = CGEventType(rawValue: ~0)!
            guard !scenes.values.contains(where: \.isVisible),
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 30 else { return }
            if freshTicks % 10 == 0 {
                refreshSnapshots(targets.filter(\.value.visible).map(\.key) + floatersShowingEverywhere())
            } else if freshTicks % 2 == 0, let id = focused {
                refreshSnapshots([id])
            }
            if freshTicks % 40 == 0 { refreshWallpapers() }
        }
    }

    func floatersShowingEverywhere() -> [WindowID] { world.monitors.indices.flatMap { floatersShowing(on: $0) } }

    func followWorkspaces(animate: Bool) {
        defer { slideVelocity = nil }
        for (m, mon) in world.monitors.enumerated() {
            let now = (id: mon.workspaces[mon.active].id, index: mon.active)
            let was = shown[mon.id]
            shown[mon.id] = now
            if let scene = scenes[mon.id], scene.isVisible {
                scene.update(sceneContent(m), animated: animate)
                scene.setNames(workspaceNames(m))
                if was?.id != now.id || overview { scene.slide(to: mon.active, velocity: slideVelocity) }
                continue
            }
            guard let was, was.id != now.id, animate, config.animations.spring(.workspaceSwitch) != nil,
                  snapshots.allowed, let scene = scene(for: m) else { continue }
            var content = sceneContent(m)
            var from = Double(was.index), to = mon.active
            if let i = mon.workspaces.firstIndex(where: { $0.id == was.id }) {
                from = Double(i)
            } else if was.index <= mon.active {
                content.insert([], at: mon.active)
                from = Double(mon.active)
                to = mon.active + 1
            } else {
                content.insert([], at: mon.active + 1)
                from = Double(mon.active + 1)
            }
            scene.show(content, at: from)
            scene.slide(to: to, velocity: slideVelocity)
            refreshSnapshots(content.flatMap { $0.map(\.id) })
        }
    }

    func setOverview(_ open: Bool, focusing picked: WindowID? = nil) {
        guard open != overview else { return }
        overview = open
        if open {
            snapshots.refreshAccess(prompt: true)
            for (m, mon) in world.monitors.enumerated() {
                guard let scene = scene(for: m) else { continue }
                let content = sceneContent(m)
                if !scene.isVisible { scene.show(content, at: Double(mon.active)) }
                scene.setNames(workspaceNames(m))
                scene.openOverview(needsAccess: !snapshots.allowed)
                scene.update(content)
                refreshSnapshots(content.flatMap { $0.map(\.id) })
            }
            updateRing(at: CACurrentMediaTime())
        } else {
            for mon in world.monitors { scenes[mon.id]?.closeOverview(at: mon.active) }
            if let picked {
                focusWindow(picked)
            } else if let id = focused, floatersShowing(on: world.focusedMonitor).contains(id) {
                focusWindow(id)
            } else {
                focusModel()
            }
        }
    }

    func scene(for m: Int) -> Scene? {
        let mon = world.monitors[m]
        if let scene = scenes[mon.id] { return scene }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == mon.id }) else { return nil }
        let scene = Scene(area: screen.visibleFrame, screen: screen.frame, wallpaper: wallpaper(screen), config: config)
        let display = mon.id
        func monitorIndex() -> Int? { world.monitors.firstIndex { $0.id == display } }
        scene.onFinished = { [weak self] in
            guard let self else { return }
            hideWhenLanded.insert(display)
            let finish = (sceneFinishes[display] ?? 0) + 1
            sceneFinishes[display] = finish
            hideLandedScenes()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, sceneFinishes[display] == finish else { return }
                hideLandedScenes(force: true)
            }
        }
        scene.onPick = { [weak self] id in
            guard let self else { return }
            if wins[id]?.floating != true { world.focus(id, config: config) }
            setOverview(false, focusing: id)
        }
        scene.onPickWorkspace = { [weak self] w in
            guard let self, let m = monitorIndex() else { return }
            world.showWorkspace(monitor: m, index: w)
            relayout()
            setOverview(false)
        }
        scene.onClose = { [weak self] in self?.setOverview(false) }
        scene.onScroll = { [weak self] e in self?.scrolledInOverview(e) }
        scene.onHint = { [weak self] w, point in
            guard let self, let m = monitorIndex() else { return nil }
            return insertHint(monitor: m, workspace: w, at: point)
        }
        scene.onDrop = { [weak self] id, w, point in
            guard let self, let m = monitorIndex() else { return }
            dropInOverview(id, monitor: m, workspace: w, at: point)
        }
        scene.onDropBetween = { [weak self] id, index in
            guard let self, let m = monitorIndex() else { return }
            world.moveToNewWorkspace(id, monitor: m, at: index, config: config)
            relayout()
        }
        scenes[display] = scene
        return scene
    }

    func hideLandedScenes(force: Bool = false) {
        for display in hideWhenLanded {
            guard let scene = scenes[display] else {
                hideWhenLanded.remove(display)
                continue
            }
            guard scene.isSettled else {
                hideWhenLanded.remove(display)
                continue
            }
            let m = world.monitors.firstIndex { $0.id == display }
            let waiting = targets.contains { id, p in p.visible && p.monitor == m && unlanded.contains(id) }
                || floatersShowing(on: m ?? -1).contains { unlanded.contains($0) }
            guard force || !waiting else { continue }
            hideWhenLanded.remove(display)
            scene.hide()
        }
        updateRing(at: CACurrentMediaTime())
    }

    func workspaceNames(_ m: Int) -> [String] {
        world.monitors[m].workspaces.enumerated().map { i, ws in ws.name ?? "\(i + 1)" }
    }

    func sceneContent(_ m: Int) -> Scene.Content {
        let mon = world.monitors[m]
        let floatingFocused = m == world.focusedMonitor && focused.flatMap { wins[$0] }?.floating == true
        let ring = floatingFocused ? nil : m == world.focusedMonitor ? config.focusRingColor : config.focusRingInactiveColor
        // Floating windows can sit above or below tiled ones; macOS decides, so the picture asks it.
        let homes = Set(mon.workspaces.map(\.id))
        let floaters = wins.values.filter { $0.floating && !$0.suspended && $0.floatHome.map(homes.contains) == true }
        let stack = floaters.isEmpty ? [:] : stackOrder()
        func depth(_ id: WindowID) -> CGFloat { wins[id].flatMap { stack[$0.windowID] } ?? 0 }
        return mon.workspaces.indices.map { w in
            let ws = mon.workspaces[w]
            let ringed = w == mon.active && !ws.columns.isEmpty && !ws.columns[ws.active].fullscreen
            var windows = world.stripFrames(monitor: m, workspace: w, config: config).map { f in
                Scene.Window(id: f.id, frame: f.frame, ring: f.active && ringed ? ring : nil, radius: cornerRadius(f.id), floating: false,
                             depth: depth(f.id), image: snapshots.images[f.id], icon: wins[f.id]?.worker.icon)
            }
            let id = mon.workspaces[w].id
            for win in wins.values where win.floating && !win.suspended && win.floatHome == id && !snapshots.blank.contains(win.id) {
                guard let f = win.floatFrame else { continue }
                windows.append(Scene.Window(id: win.id, frame: f.offsetBy(dx: -mon.area.minX, dy: -mon.area.minY),
                                            ring: nil, radius: cornerRadius(win.id), floating: true, depth: depth(win.id), image: snapshots.images[win.id], icon: win.worker.icon))
            }
            return windows
        }
    }

    // Front to back, as 1 down to 0.
    func stackOrder() -> [CGWindowID: CGFloat] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        return Dictionary(ids.enumerated().map { ($1, CGFloat(ids.count - $0) / CGFloat(max(ids.count, 1))) }, uniquingKeysWith: { a, _ in a })
    }

    func insertHint(monitor m: Int, workspace w: Int, at point: CGPoint) -> CGRect? {
        let gap = config.gap, area = world.monitors[m].area
        let frames = world.stripFrames(monitor: m, workspace: w, config: config)
        let bar = max(gap, 12)
        switch world.insertPosition(monitor: m, workspace: w, at: point, config: config) {
        case .newColumn(let c):
            let ws = world.monitors[m].workspaces[w]
            let x: Double
            if ws.columns.isEmpty {
                return CGRect(x: gap, y: gap, width: area.width - 2 * gap, height: area.height - 2 * gap)
            } else if c < ws.columns.count, let f = frames.first(where: { ws.columns[c].windows.contains($0.id) }) {
                x = f.frame.minX - gap / 2
            } else if let f = frames.first(where: { ws.columns[ws.columns.count - 1].windows.contains($0.id) }) {
                x = f.frame.maxX + gap / 2
            } else {
                return nil
            }
            return CGRect(x: x - bar / 2, y: gap, width: bar, height: area.height - 2 * gap)
        case .inColumn(let c, let t):
            let ws = world.monitors[m].workspaces[w]
            let tiles = ws.columns[c].windows.compactMap { id in frames.first { $0.id == id }?.frame }
            guard let first = tiles.first else { return nil }
            let y = t < tiles.count ? tiles[t].minY - gap / 2 : tiles[tiles.count - 1].maxY + gap / 2
            return CGRect(x: first.minX, y: y - bar / 2, width: first.width, height: bar)
        }
    }

    func dropInOverview(_ id: WindowID, monitor m: Int, workspace w: Int, at point: CGPoint) {
        guard let win = wins[id] else { return }
        if win.floating {
            let area = world.monitors[m].area
            if let f = win.floatFrame {
                win.floatFrame = CGRect(x: area.minX + point.x - f.width / 2, y: area.minY + point.y - 20, width: f.width, height: f.height)
            }
            win.floatHome = world.monitors[m].workspaces[w].id
            floatHidden.insert(id)
        } else {
            let position = world.insertPosition(monitor: m, workspace: w, at: point, config: config)
            world.move(id, to: m, workspace: w, at: position, config: config)
        }
        relayout()
    }

    func scrolledInOverview(_ e: NSEvent) {
        guard e.momentumPhase.isEmpty else { return }
        guard e.hasPreciseScrollingDeltas else { return scrolled(.wheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)) }
        switch e.phase {
        case .began: scrolled(.began)
        case .changed: scrolled(.changed(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, time: e.timestamp))
        case .ended, .cancelled: scrolled(.ended(time: e.timestamp))
        default: break
        }
    }

    func refreshSnapshots(_ ids: [WindowID]) {
        let list = ids.compactMap { id in wins[id].map { (id: id, windowID: $0.windowID) } }
        snapshots.refresh(list, scale: NSScreen.main?.backingScaleFactor ?? 2) { [weak self] id in
            guard let self, let image = snapshots.images[id] else { return }
            for scene in scenes.values { scene.setContents(image, for: id) }
        }
    }

    func scheduleWarmup() {
        warmup?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !motion.isMoving, snapshots.allowed else { return }
            refreshSnapshots(targets.filter(\.value.visible).map(\.key) + floatersShowingEverywhere())
        }
        warmup = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func wallpaper(_ screen: NSScreen) -> Any? {
        if let image = wallpapers[screen.displayID] { return image }
        let file = NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        return file?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func refreshWallpapers() {
        snapshots.captureWallpapers { [weak self] images in
            guard let self else { return }
            wallpapers.merge(images) { _, new in new }
            for (display, image) in images { scenes[display]?.setWallpaper(image) }
        }
    }

    func rebuildScenes() {
        for scene in scenes.values { scene.close() }
        scenes = [:]
        hideWhenLanded = []
        guard snapshots.allowed else { return }
        for m in world.monitors.indices { _ = scene(for: m) }
    }
}
