import AppKit
import QuartzCore
import TegiCore

/// The window server presents windows where tegi puts them, on tegi's own compositor thread; apps hear where their
/// windows are when a flight lands. It needs the Dock's grant: until then, or once macOS refuses a move, windows stay
/// where they are and `problem` says why.
final class DirectMotion: MotionMode {
    unowned let wm: WindowManager
    let server: WindowServer
    let compositor: Compositor
    /// Shown somewhere Accessibility hasn't been told about.
    var unsynced: Set<WindowID> = []
    private var authorizationAttempted = false
    private var scenesLive = false

    init(_ wm: WindowManager) {
        self.wm = wm
        server = wm.windowServer
        compositor = Compositor(server: server)
        compositor.onCommit = { [weak wm] settled in wm?.presentationCommitted(settled: settled) }
        server.onChange = { [weak self] in self?.changed() }
        server.onRefused = { [weak self] in
            guard let self else { return }
            finish(restoring: [:])
            changed()
        }
        wm.motion.onFlights = { [weak self] flights in
            guard let self, server.active else { return }
            compositor.fly(flights)
        }
    }

    var presents: Bool { true }
    var liveScenes: Bool { server.liveScenes }
    var problem: String? { server.problem }

    func start() {
        server.configure(enabled: true)
        authorizationAttempted = false
    }

    func stop() {
        finish(restoring: [:])
        server.configure(enabled: false)
        scenesLive = server.liveScenes
        // Off, tegi gives back what it was trusted with: sudo stops running its loader without a password.
        WindowServer.forget(asking: true)
    }

    func sync() {
        requestAuthorization()
        update()
    }

    func update() {
        guard !wm.paused, server.active else { return }
        let managed = wm.wins.values.filter {
            $0.windowID != 0 && !$0.fullScreen && !$0.suspended && !wm.nativeMoving.contains($0.id)
        }
        compositor.update(world: wm.world, windows: Dictionary(uniqueKeysWithValues: managed.map { ($0.id, $0.windowID) }), excluded: Set(wm.wins.values.filter {
            $0.fullScreen || $0.suspended || wm.nativeMoving.contains($0.id)
        }.map(\.windowID)), clips: Dictionary(uniqueKeysWithValues: managed.map { ($0.windowID, clip($0.id)) }),
                          appOwned: Set(managed.filter(\.popup).map(\.windowID)))
        wm.watchWindowOrder()
    }

    func layout(_ placements: [WindowID: Placement]) -> [WindowID: Placement] { placements }

    func start(_ id: WindowID, at now: CFTimeInterval) -> CGRect? { presented(id) }

    func flying(_ id: WindowID, from: CGRect, to: CGRect) {
        guard server.active, wm.wins[id]?.windowID != 0 else { return }
        if from.size != to.size { requestSize(id, to) }
        unsynced.insert(id)
    }

    func rest(_ id: WindowID, _ p: Placement) -> CGRect {
        let origin = wm.applied[id]?.origin ?? wm.wins[id]?.original?.origin ?? p.frame.origin
        return p.strip ?? CGRect(origin: origin, size: p.frame.size)
    }

    func step(_ id: WindowID, _ frame: CGRect, monitor: Int, last: Bool) {
        // The compositor presents the flight; landing is where Accessibility hears where the window is.
        if last { wm.send(id: id, frame, verify: true) }
    }

    /// App geometry can change under locked bounds without moving or resizing the displayed window.
    func send(_ id: WindowID, _ frame: CGRect, verify: Bool) {
        guard server.active, let win = wm.wins[id] else { return }
        if win.popup {
            // Popups can finish positioning after discovery; tegi owns their visibility, not their geometry.
            compositor.place(id, frame: frame, clip: clip(id))
            return
        }
        let before = wm.applied[id]
        let clip = clip(id)
        if before?.size != frame.size { wm.verified.remove(id) }
        wm.applied[id] = frame
        wm.updateLiveFloating(win)
        compositor.place(id, frame: frame, clip: clip)
        wm.sentSomething = true
        if before != frame { unsynced.insert(id) }
        // Hidden and partly exposed windows keep their logical position on a display, where AppKit can resize them.
        // Their presentation is independent, so neither clamping nor a late AX answer can expose a correction.
        let landing = verify && wm.swipe?.axis != .horizontal && wm.world.monitors.contains { $0.screen.contains(frame) } && !clip.isEmpty
        if landing {
            wm.sendAccessibility(id, frame, verify: !wm.verified.contains(id), force: unsynced.contains(id))
        } else if before?.size != frame.size {
            requestSize(id, frame)
        }
    }

    func hide(_ win: Win, size: CGSize, on monitor: Int) -> CGRect {
        win.floatFrame ?? CGRect(origin: wm.world.monitors[monitor].area.origin, size: size)
    }

    func landed(_ id: WindowID) { unsynced.remove(id) }

    func finish(restoring restored: [WindowID: CGRect]) {
        // A window tegi never placed, as before the Dock's grant, is still where its owner left it.
        var frames = restored.filter { wm.applied[$0.key] != nil && wm.wins[$0.key]?.popup != true }
        for id in unsynced where frames[id] == nil { frames[id] = wm.applied[id] }
        // Keep the server's presentation until native geometry is ready to be shown again.
        wm.handBack(frames)
        compositor.endAll()
        unsynced = []
    }

    func release(_ id: WindowID) {
        compositor.release(id)
        unsynced.remove(id)
    }

    func shown(_ id: WindowID, at now: CFTimeInterval) -> CGRect? {
        guard server.active else { return nil }
        if let win = wm.wins[id], let shown = server.presentation(of: win.windowID) {
            guard shown.clip.map({ !$0.isEmpty && $0.intersects(shown.frame) }) ?? true else { return nil }
            return shown.frame
        }
        if let grabbed = wm.grabbed(id) { return grabbed }
        guard let frame = wm.laidOut(id, at: now) else { return nil }
        return wm.refusals[id]?.apply(to: frame) ?? frame
    }

    func presented(_ id: WindowID) -> CGRect? {
        wm.wins[id].flatMap { server.presentation(of: $0.windowID)?.frame }
    }

    func refresh(_ id: WindowID) {
        if let win = wm.wins[id] { server.refreshContent(of: win.windowID) }
    }

    func size(of win: Win) -> CGSize? { server.contentBounds(of: win.windowID)?.size }

    func force(_ id: WindowID, _ frame: CGRect) { requestSize(id, frame) }

    func heard(_ id: WindowID) -> Bool {
        guard server.active else { return false }
        if wm.wins[id]?.popup == true { return true }
        if yieldToNative(id) { return true }
        update()
        return false
    }

    func pressed(_ id: WindowID) -> Bool { wm.nativePressed == id }

    func echoes(_ id: WindowID) -> Bool { false }

    func smoothness(_ summary: String) -> String {
        String(format: "WindowServer commit: %.2f ms average, %.2f ms peak", server.meanCommitMS, server.maxCommitMS)
    }

    /// A press in another app must not turn an AX echo into a native drag of this window.
    func yieldToNative(_ id: WindowID) -> Bool {
        if wm.nativeMoving.contains(id) { return true }
        guard server.active, wm.nativePressed == id, wm.grab == nil, let win = wm.wins[id] else { return false }
        wm.nativeMoving.insert(id)
        wm.motion.stop(id, at: nil)
        compositor.release(id)
        win.worker.cancelPosition(id)
        return true
    }

    func clip(_ id: WindowID) -> CGRect {
        let monitor = wm.world.locate(id)?.monitor ?? wm.wins[id].flatMap(wm.floatMonitor)
        if let monitor, wm.world.monitors.indices.contains(monitor),
           let scene = wm.scenes[wm.world.monitors[monitor].id], scene.isVisible, !scene.inOverview, !scene.isSettled,
           let win = wm.wins[id], let clip = server.presentation(of: win.windowID)?.clip, !clip.isEmpty {
            // Outgoing windows keep drawing until handoff. Incoming ones must become visible underneath the
            // preview now, so their apps can lay out and render before the slide finishes.
            return clip
        }
        if let win = wm.wins[id], win.floating {
            guard let m = wm.floatMonitor(win), wm.world.monitors.indices.contains(m),
                  win.floatHome == wm.activeWorkspaceID(on: m) else { return .zero }
            return wm.world.monitors[m].screen
        }
        guard let location = wm.world.locate(id), wm.world.monitors.indices.contains(location.monitor) else { return .zero }
        let mon = wm.world.monitors[location.monitor]
        let ws = mon.workspaces[location.workspace]
        let column = ws.columns[location.column]
        guard location.workspace == mon.active, !column.tabbed || column.activeWindow == id else { return .zero }
        return mon.screen
    }

    func requestSize(_ id: WindowID, _ frame: CGRect) {
        guard let win = wm.wins[id], !win.popup else { return }
        let size = frame.size
        var content = frame
        if let m = wm.world.locate(id)?.monitor ?? wm.floatMonitor(win), wm.world.monitors.indices.contains(m) {
            let mon = wm.world.monitors[m]
            if !mon.screen.contains(content) { content.origin = mon.area.origin }
        }
        wm.verified.remove(id)
        unsynced.insert(id)
        // A bottom tile cannot grow to full height at its old native origin: macOS clamps it to the screen edge.
        // Locked bounds keep the visible flight in place while the app moves first and lays out its destination size.
        win.worker.apply(id, win.element, content, resize: true, placed: true,
                         measured: { [weak wm] id, actual in
            guard let wm, wm.wins[id] != nil else { return }
            let wanted = wm.motion.isFlying(id) ? wm.targets[id]?.strip?.size : wm.applied[id]?.size
            guard wanted == size else { return }
            wm.sizeAnswered(id, asked: size, actual: actual)
        }, done: { [weak wm] in wm?.contentAnswered(id) })
    }

    private func requestAuthorization() {
        guard server.wanted, !authorizationAttempted,
              wm.wins.values.contains(where: { !$0.suspended && $0.windowID != 0 }) else { return }
        authorizationAttempted = true
        server.authorizeLiveScenes()
    }

    private func changed() {
        if server.active, !scenesLive {
            update()
            wm.motion.republish()
        }
        if scenesLive != server.liveScenes {
            scenesLive = server.liveScenes
            wm.liveScenesChanged()
        }
        wm.onChange()
    }
}
