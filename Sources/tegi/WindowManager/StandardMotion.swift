import AppKit
import TegiCore

/// Every frame of a flight goes to the app through Accessibility, and the app moves its own window when it gets to it,
/// so the screen trails what tegi sends.
final class StandardMotion: MotionMode {
    unowned let wm: WindowManager

    init(_ wm: WindowManager) { self.wm = wm }

    var presents: Bool { false }
    var liveScenes: Bool { false }
    var problem: String? { nil }

    func start() {}
    func stop() {}
    func sync() {}

    func layout(_ placements: [WindowID: Placement]) -> [WindowID: Placement] {
        var placements = placements
        for (id, var p) in placements {
            guard let frame = p.strip else { continue }
            let mon = wm.world.monitors[p.monitor]
            guard frame.minY < mon.area.minY - 1 else { continue }
            // AX clamps title bars above the screen back into the stack. Only the compositor can clip them there.
            let others = wm.world.monitors.enumerated().filter { $0.offset != p.monitor }.map(\.element.screen)
            p.frame = wm.world.park(frame.size, area: mon.area, others: others)
            p.visible = false
            p.strip = nil
            placements[id] = p
        }
        return placements
    }

    func start(_ id: WindowID, at now: CFTimeInterval) -> CGRect? {
        guard !wm.motion.isFlying(id), wm.targets[id]?.visible == true else { return nil }
        return wm.shownFrame(id, at: now)
    }

    func flying(_ id: WindowID, from: CGRect, to: CGRect) {}

    func rest(_ id: WindowID, _ p: Placement) -> CGRect { p.frame }

    func step(_ id: WindowID, _ frame: CGRect, monitor: Int, last: Bool) {
        wm.send(id: id, wm.world.place(frame, on: monitor).frame, verify: last)
    }

    func send(_ id: WindowID, _ frame: CGRect, verify: Bool) {
        wm.sendAccessibility(id, frame, verify: verify)
    }

    func hide(_ win: Win, size: CGSize, on monitor: Int) -> CGRect {
        wm.world.place(CGRect(origin: CGPoint(x: -1_000_000, y: 0), size: size), on: monitor).frame
    }

    func landed(_ id: WindowID) {}

    func finish(restoring restored: [WindowID: CGRect]) { wm.handBack(restored) }

    func release(_ id: WindowID) {}

    func shown(_ id: WindowID, at now: CFTimeInterval) -> CGRect? {
        if let grabbed = wm.grabbed(id) { return grabbed }
        guard let frame = wm.laidOut(id, at: now) else { return nil }
        // App replies and the spring can finish before the final frame reaches the screen.
        if let wid = wm.wins[id]?.windowID, wid != 0 {
            guard let at = wm.onScreen(wid), wm.world.monitors.contains(where: { $0.screen.intersection(at).width > 40 }) else { return nil }
            return at
        }
        return wm.refusals[id]?.apply(to: frame) ?? frame
    }

    func presented(_ id: WindowID) -> CGRect? { nil }

    func refresh(_ id: WindowID) {}

    func size(of win: Win) -> CGSize? { wm.onScreen(win.windowID)?.size }

    func force(_ id: WindowID, _ frame: CGRect) { wm.sendAccessibility(id, frame, verify: true, force: true) }

    func heard(_ id: WindowID) -> Bool { true }

    func pressed(_ id: WindowID) -> Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    func echoes(_ id: WindowID) -> Bool {
        guard let win = wm.wins[id], !win.fullScreen, !wm.verified.contains(id), NSEvent.pressedMouseButtons & 1 == 0 else { return false }
        return wm.motion.isFlying(id) || wm.unlanded.contains(id)
    }

    func smoothness(_ summary: String) -> String { summary }
}
