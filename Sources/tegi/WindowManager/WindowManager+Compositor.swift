import AppKit
import QuartzCore
import TegiCore

extension WindowManager {
    func startCompositor() {
        compositor.onCommit = { [weak self] settled in self?.presentationCommitted(settled: settled) }
        windowServer.onRefused = { [weak self] in
            guard let self else { return }
            finishServerMotion()
            serverBackendChanged()
        }
        motion.onFlights = { [weak self] flights in
            guard let self, windowServer.active else { return }
            compositor.fly(flights)
        }
    }

    func updateCompositor() {
        guard !paused, windowServer.active else { return }
        let managed = wins.values.filter {
            $0.windowID != 0 && !$0.fullScreen && !$0.suspended && !nativeMoving.contains($0.id)
        }
        compositor.update(world: world, windows: Dictionary(uniqueKeysWithValues: managed.map { ($0.id, $0.windowID) }), excluded: Set(wins.values.filter {
            $0.fullScreen || $0.suspended || nativeMoving.contains($0.id)
        }.map(\.windowID)), clips: Dictionary(uniqueKeysWithValues: managed.map { ($0.windowID, serverClip($0.id)) }))
    }

    func familyChanged() {
        updateCompositor()
        presentationCommitted(settled: !motion.isMoving)
    }

    func serverClip(_ id: WindowID) -> CGRect {
        if let win = wins[id], win.floating {
            guard let m = floatMonitor(win), world.monitors.indices.contains(m),
                  win.floatHome == activeWorkspaceID(on: m) else { return .zero }
            return world.monitors[m].screen
        }
        guard let location = world.locate(id), world.monitors.indices.contains(location.monitor) else { return .zero }
        let mon = world.monitors[location.monitor]
        let ws = mon.workspaces[location.workspace]
        let column = ws.columns[location.column]
        guard location.workspace == mon.active, !column.tabbed || column.activeWindow == id else { return .zero }
        return mon.screen
    }

    /// App geometry can change under locked bounds without moving or resizing the displayed window.
    func sendThroughServer(_ id: WindowID, _ frame: CGRect, verify: Bool) {
        guard let win = wins[id] else { return }
        let before = applied[id]
        let clip = serverClip(id)
        if before?.size != frame.size { verified.remove(id) }
        applied[id] = frame
        updateLiveFloating(win)
        compositor.place(id, frame: frame, clip: clip)
        sentSomething = true
        if before != frame { serverUnsynced.insert(id) }
        // Hidden and partly exposed windows keep their logical position on a display, where AppKit can resize them.
        // Their presentation is independent, so neither clamping nor a late AX answer can expose a correction.
        let landing = verify && swipe?.axis != .horizontal && world.monitors.contains { $0.screen.contains(frame) } && !clip.isEmpty
        if landing {
            sendAccessibility(id, frame, verify: !verified.contains(id), force: serverUnsynced.contains(id))
        } else if before?.size != frame.size {
            requestSize(id, frame)
        }
    }

    func requestSize(_ id: WindowID, _ frame: CGRect) {
        guard let win = wins[id] else { return }
        let size = frame.size
        var content = frame
        if let m = world.locate(id)?.monitor ?? floatMonitor(win), world.monitors.indices.contains(m) {
            let mon = world.monitors[m]
            if !mon.screen.contains(content) { content.origin = mon.area.origin }
        }
        verified.remove(id)
        serverUnsynced.insert(id)
        // A bottom tile cannot grow to full height at its old native origin: macOS clamps it to the screen edge.
        // Locked bounds keep the visible flight in place while the app moves first and lays out its destination size.
        win.worker.apply(id, win.element, content, resize: true, placed: true,
                         measured: { [weak self] id, actual in
            guard let self, wins[id] != nil else { return }
            let wanted = motion.isFlying(id) ? targets[id]?.strip?.size : applied[id]?.size
            guard wanted == size else { return }
            sizeAnswered(id, asked: size, actual: actual)
        }, done: { [weak self] in self?.contentAnswered(id) })
    }

    func contentAnswered(_ id: WindowID) {
        guard !paused, windowServer.active, let win = wins[id] else { return }
        windowServer.refreshContent(of: win.windowID)
        presentationCommitted(settled: true)
    }

    func presentationCommitted(settled: Bool) {
        guard !paused, windowServer.active else { return }
        updateRing(at: motion.clock)
        guard settled else { return }
        for (m, mon) in world.monitors.enumerated() where scenes[mon.id]?.isVisible == true {
            scenes[mon.id]?.update(sceneContent(m, current: true))
        }
        onChange()
    }

    func finishServerMotion(restoring restored: [WindowID: CGRect] = [:]) {
        for id in serverUnsynced.union(restored.keys) {
            guard let frame = restored[id] ?? applied[id] else { continue }
            sendAccessibility(id, frame, verify: true, force: true)
        }
        // Keep the server's presentation until native geometry is ready to be shown again.
        let group = DispatchGroup()
        for worker in workers.values { worker.flush(group) }
        _ = group.wait(timeout: .now() + 2)
        compositor.endAll()
        serverUnsynced = []
    }

    func requestServerAuthorization() {
        guard windowServer.wanted, !serverAuthorizationAttempted,
              wins.values.contains(where: { !$0.suspended && $0.windowID != 0 }) else { return }
        serverAuthorizationAttempted = true
        windowServer.authorizeLiveScenes()
    }

    func serverBackendChanged() {
        if windowServer.active, !serverScenesLive {
            updateCompositor()
            motion.republish()
        }
        if serverScenesLive != windowServer.liveScenes {
            serverScenesLive = windowServer.liveScenes
            let open = overview
            overview = false
            rebuildScenes()
            applied = [:]
            relayout()
            if open { setOverview(true) }
        }
        onChange()
    }

    func updateLiveFloating(_ win: Win) {
        guard windowServer.liveScenes, win.floating, let frame = win.floatFrame,
              let monitor = floatMonitor(win), world.monitors.indices.contains(monitor) else { return }
        let mon = world.monitors[monitor]
        guard scenes[mon.id]?.isVisible == true else { return }
        scenes[mon.id]?.setFrames([win.id: frame.offsetBy(dx: -mon.area.minX, dy: -mon.area.minY)])
    }

    func sizeChanged(_ id: WindowID) {
        guard !paused, let win = wins[id], !win.floating, !win.suspended, !win.fullScreen, win.windowID != 0, let laidOut = applied[id],
              !motion.isFlying(id), let real = (windowServer.active ? windowServer.contentBounds(of: win.windowID) : onScreen(win.windowID))?.size else { return }
        let off = abs(real.width - laidOut.width) > 1 || abs(real.height - laidOut.height) > 1
        if let limit = world.heightLimit(for: id), real.height < limit.height - 1,
           world.observeSize(real, asked: laidOut.size, for: id) { return relayout() }
        refusals[id] = off ? Refusal(asked: laidOut.size, got: real) : nil
        if !off { forced[id] = nil }
        updateRing(at: motion.clock)
        guard off, !unlanded.contains(id), forced[id] != laidOut.size else { return }
        forced[id] = laidOut.size
        if windowServer.active { requestSize(id, laidOut) }
        else { sendAccessibility(id, laidOut, verify: true, force: true) }
    }
}
