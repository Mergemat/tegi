import AppKit
import QuartzCore
import TegiCore

/// WindowServer motion: the compositor moves windows every frame; this side keeps Accessibility's idea of each window,
/// and what tegi has asked of it, in step. A window changing size is moved and resized by its app, as in standard
/// motion: only the app can redraw at a new size, and a position from elsewhere would fight the one it applies.
extension WindowManager {
    func startCompositor() {
        windowServer.onRefused = { [weak self] in
            guard let self else { return }
            finishServerMotion()
            onChange()
        }
        motion.onFlights = { [weak self] flights in
            guard let self, windowServer.active else { return }
            let sized = appSized
            compositor.fly(flights.filter { !sized.contains($0.key) })
        }
    }

    /// What the compositor presents from: the layout, and which windows it may move.
    func updateCompositor() {
        guard windowServer.active else { return }
        compositor.update(world: world, windows: Dictionary(uniqueKeysWithValues: wins.values.filter { $0.windowID != 0 }.map { ($0.id, $0.windowID) }))
    }

    /// A window put somewhere directly, or landing from a flight the compositor already presented.
    func sendThroughServer(_ id: WindowID, _ frame: CGRect, verify: Bool) {
        guard let win = wins[id] else { return }
        let before = applied[id]
        let resize = before?.size != frame.size
        let changed = before != frame
        guard changed || resize || verify && serverUnsynced.contains(id) else { return }
        applied[id] = frame
        updateLiveFloating(win)
        serverUnsynced.insert(id)
        compositor.place(id, at: frame.origin)
        sentSomething = true
        if changed {
            generation[id, default: 0] += 1
            unlanded.remove(id)
            win.worker.cancelPosition(id)
            motion.sent(id, app: win.worker.name)
            motion.landed(id)
        }
        // Apps clamp parked and partly off-screen windows back onto a display when AX is told
        // their position. Keep those in compositor coordinates until they're fully exposed.
        let landing = verify && !unlanded.contains(id) && swipe?.axis != .horizontal && world.monitors.contains(where: { $0.screen.contains(frame) })
        if resize {
            verified.remove(id)
            if !landing { requestSize(id, frame.size, at: frame.origin) }
        }
        // What the app refuses is measured once the window is where it belongs.
        if landing { sendAccessibility(id, frame, verify: !verified.contains(id), force: true) }
    }

    /// A size for a window parked or on its way. AppKit applies a size where the app last heard its window was, which
    /// compositor moves never tell it, so a window at rest has the app hear `origin`, where the compositor has it,
    /// first. One in flight gets the size alone: a place would pull it back for a frame. Either way, an app that
    /// nudges the window is put back once it's done.
    func requestSize(_ id: WindowID, _ size: CGSize, at origin: CGPoint?) {
        guard let win = wins[id] else { return }
        win.worker.apply(id, win.element, CGRect(origin: origin ?? .zero, size: size), resize: true, position: origin != nil,
                         placed: true, measured: { _, _ in }, done: { [weak self] in self?.compositor.reassert(id) })
    }

    func finishServerMotion() {
        compositor.endAll()
        for id in serverUnsynced {
            guard let frame = applied[id] else { continue }
            sendAccessibility(id, frame, verify: true, force: true)
        }
        serverUnsynced = []
    }

    func requestServerAuthorization() {
        guard windowServer.wanted, !serverAuthorizationAttempted,
              wins.values.contains(where: { !$0.suspended && $0.windowID != 0 }) else { return }
        serverAuthorizationAttempted = true
        windowServer.authorizeLiveScenes()
    }

    func serverBackendChanged() {
        // Granted mid-flight: what Motion is flying is the compositor's from here.
        if windowServer.active, !serverScenesLive {
            updateCompositor()
            motion.republish()
        }
        if serverScenesLive != windowServer.liveScenes {
            serverScenesLive = windowServer.liveScenes
            let open = overview
            overview = false
            rebuildScenes()
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

    /// A window's size as the window server has it is the truth the ring and overview follow. An app that resized itself,
    /// often restoring a saved frame after it opens, is told the layout's size once more; one that keeps another size
    /// after being told is refusing it, and is left be until the layout asks for something else.
    func sizeChanged(_ id: WindowID) {
        guard let win = wins[id], !win.floating, !win.suspended, win.windowID != 0, let laidOut = applied[id],
              !motion.isFlying(id), let real = onScreen(win.windowID)?.size else { return }
        let off = abs(real.width - laidOut.width) > 1 || abs(real.height - laidOut.height) > 1
        refusals[id] = off ? Refusal(asked: laidOut.size, got: real) : nil
        if !off { forced[id] = nil }
        updateRing(at: motion.clock)
        // While tegi's own ask is out, a new size is the app's answer to it.
        guard off, !unlanded.contains(id), forced[id] != laidOut.size else { return }
        forced[id] = laidOut.size
        if windowServer.active { requestSize(id, laidOut.size, at: laidOut.origin) }
        else { sendAccessibility(id, laidOut, verify: true, force: true) }
    }
}
