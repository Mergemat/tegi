import AppKit
import QuartzCore
import TegiCore

extension WindowManager {
    func familyChanged() {
        mode.sync()
        presentationCommitted(settled: !motion.isMoving)
    }

    func contentAnswered(_ id: WindowID) {
        guard !paused, wins[id] != nil else { return }
        mode.refresh(id)
        presentationCommitted(settled: !motion.isMoving)
    }

    func presentationCommitted(settled: Bool) {
        guard !paused else { return }
        updateRing(at: motion.clock)
        guard settled else { return }
        for (m, mon) in world.monitors.enumerated() where scenes[mon.id]?.isVisible == true {
            scenes[mon.id]?.update(sceneContent(m, current: true))
        }
        onChange()
    }

    func liveScenesChanged() {
        let open = overview
        overview = false
        rebuildScenes()
        applied = [:]
        relayout()
        if open { setOverview(true) }
    }

    func updateLiveFloating(_ win: Win) {
        guard mode.liveScenes, win.floating, let frame = win.floatFrame,
              let monitor = floatMonitor(win), world.monitors.indices.contains(monitor) else { return }
        let mon = world.monitors[monitor]
        guard scenes[mon.id]?.isVisible == true else { return }
        scenes[mon.id]?.setFrames([win.id: frame.offsetBy(dx: -mon.area.minX, dy: -mon.area.minY)])
    }

    func sizeChanged(_ id: WindowID) {
        guard !paused, let win = wins[id], !win.floating, !win.suspended, !win.fullScreen, win.windowID != 0, let laidOut = applied[id],
              !motion.isFlying(id), let real = mode.size(of: win) else { return }
        let off = abs(real.width - laidOut.width) > 1 || abs(real.height - laidOut.height) > 1
        if let limit = world.heightLimit(for: id), real.height < limit.height - 1,
           world.observeSize(real, asked: laidOut.size, for: id) { return relayout() }
        refusals[id] = off ? Refusal(asked: laidOut.size, got: real) : nil
        if !off { forced[id] = nil }
        updateRing(at: motion.clock)
        guard off, !unlanded.contains(id), forced[id] != laidOut.size else { return }
        forced[id] = laidOut.size
        mode.force(id, laidOut)
    }
}
