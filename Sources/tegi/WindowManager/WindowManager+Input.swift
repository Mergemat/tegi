import AppKit
import QuartzCore
import TegiCore

struct Swipe {
    enum Axis { case horizontal, vertical }
    var monitor: Int
    var origin: Double
    var tracker = SwipeTracker()
    var axis: Axis?
    var pending = CGVector.zero
    var startIndex: Int?
}

/// Four fingers opening or closing the overview as they go, as Mission Control does.
struct OverviewSwipe {
    /// Points of travel that open it fully: about a third of the trackpad's height.
    static let travel = 200.0
    var from: Double
    var tracker = SwipeTracker()

    var openness: Double { RubberBand.workspaces.clamp(from + tracker.position / Self.travel, 0, 1) }
    /// Where a release coasts to, open or shut, and how fast it's opening per second as it does.
    var release: (open: Bool, rate: Double) { (from + tracker.projectedEnd / Self.travel > 0.5, tracker.velocity / Self.travel) }
}

struct Grab {
    var window: WindowID
    var resize: Bool
    var start: CGPoint
    var frame: CGRect
    var floating: Bool
    var current: CGRect
    // The tap swallows the drag, so the system pointer position stays where it began.
    var point: CGPoint
    var edge: (monitor: Int, speed: Double, since: Double, last: Double)?
}

extension WindowManager {
    func startInput() {
        cancelOverviewSwipe()
        if grab != nil { endGrab() }
        if let s = swipe, s.axis != nil { scrolled(.ended(time: CACurrentMediaTime())) }
        swipe = nil
        let scrolling = input?.stop() ?? ScrollInput()
        multitouch?.shutdown()
        inputTrace.record(["kind": "reset", "paused": paused, "three_finger_swipe": config.threeFingerSwipe,
                           "owner": scrolling.owner?.rawValue ?? "none"])
        multitouch = config.threeFingerSwipe && !paused ? Multitouch(trace: inputTrace) { [weak self] in self?.touch($0) } : nil
        let touch = multitouch
        touch?.blockTouches(scrolling.blocksTouches)
        input = InputTap(modifier: paused ? [] : config.swipeModifier, trace: inputTrace, scrolling: scrolling,
                         scrollRouting: { touch?.scrollRouting ?? .system },
                         blockTouches: { touch?.blockTouches($0) }) { [weak self] in self?.inputEvent($0) }
        inputTrace.record(["kind": "availability", "reader_available": multitouch != nil, "tap_available": input != nil])
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return }
                pendingFocus = nil
                if event.type == .leftMouseDown { nativePressed = window(at: pointer()) }
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                self?.nativePressed = nil
                self?.nativeDragEnded()
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.pointerMoved() },
        ].compactMap { $0 }
    }

    var threeFingerConflict: Bool {
        guard config.threeFingerSwipe else { return false }
        let trackpad = UserDefaults.standard.persistentDomain(forName: "com.apple.AppleMultitouchTrackpad")
        return (trackpad?["TrackpadThreeFingerHorizSwipeGesture"] as? Int ?? 0) != 0
            || (trackpad?["TrackpadThreeFingerVertSwipeGesture"] as? Int ?? 0) != 0
    }

    func inputEvent(_ event: InputTap.Event) {
        switch event {
        case .began: scrolled(.began)
        case .changed(let dx, let dy, let t): scrolled(.changed(dx: dx, dy: dy, time: t))
        case .ended(let t): scrolled(.ended(time: t))
        case .momentum(let dx, _, let t): scrolled(.momentum(dx: dx, time: t))
        case .momentumEnded: scrolled(.momentumEnded)
        case .wheel(let dx, let dy): scrolled(.wheel(dx: dx, dy: dy))
        case .grab(let right, let point): beginGrab(at: point, resize: right)
        case .drag(let point): moveGrab(to: point)
        case .release: endGrab()
        }
    }

    /// Four fingers. Three scroll the strip through the scroll events macOS makes of them, as anything scrolls on a Mac.
    func touch(_ event: Multitouch.Event) {
        guard !paused else { return }
        switch event {
        case .began(let fingers):
            if fingers == 4 { beginOverviewSwipe() }
        case .changed(_, let dy, let t):
            // Opening is up the trackpad, or down with natural scrolling off, as macOS's own is.
            followOverviewSwipe(-dy * 600, at: t)
        case .ended:
            endOverviewSwipe()
        case .cancelled:
            cancelOverviewSwipe()
        }
    }

    func cancelOverviewSwipe() {
        guard let swipe = overviewSwipe else { return }
        overviewSwipe = nil
        setOverview(swipe.from >= 0.5)
    }

    func beginOverviewSwipe() {
        let swipe = OverviewSwipe(from: overview ? 1 : 0)
        overviewSwipe = swipe
        // Shown at once, at whatever openness the fingers are at.
        if !overview { setOverview(true) }
        followOverview(swipe.openness)
    }

    func followOverviewSwipe(_ opening: Double, at time: Double) {
        guard var swipe = overviewSwipe else { return }
        swipe.tracker.push(opening, at: time)
        overviewSwipe = swipe
        followOverview(swipe.openness)
    }

    func endOverviewSwipe() {
        guard let swipe = overviewSwipe else { return }
        overviewSwipe = nil
        let (open, rate) = swipe.release
        guard open, overview else { return setOverview(open, velocity: rate) }
        for scene in scenes.values where scene.inOverview { scene.openOverview(velocity: scene.zoomVelocity(opening: rate)) }
    }

    private func followOverview(_ openness: Double) {
        for scene in scenes.values where scene.inOverview { scene.followOverview(openness) }
    }

    enum Scroll {
        case began
        case changed(dx: Double, dy: Double, time: Double)
        case ended(time: Double)
        case momentum(dx: Double, time: Double)
        case momentumEnded
        case wheel(dx: Double, dy: Double)
    }

    func scrolled(_ event: Scroll) {
        guard !paused else { return }
        switch event {
        case .began:
            let m = pointerMonitor() ?? world.focusedMonitor
            var origin = world.viewPosition(monitor: m, config: config)
            let now = max(CACurrentMediaTime(), motion.clock)
            // The model already holds the last flick's destination; fingers take over where the strip is visible now.
            for (id, target) in targets where target.monitor == m {
                guard let strip = target.strip, let current = motion.current(id, at: now), current.monitor == m else { continue }
                origin += strip.minX - current.frame.minX
                break
            }
            world.scrollView(monitor: m, to: origin, config: config)
            swipe = Swipe(monitor: m, origin: origin)
            relayout(tracking: true)
        case .changed(var dx, var dy, let time):
            guard var s = swipe else { return }
            if s.axis == nil {
                s.pending.dx += dx
                s.pending.dy += dy
                guard hypot(s.pending.dx, s.pending.dy) >= 4 else { return swipe = s }
                s.axis = abs(s.pending.dx) >= abs(s.pending.dy) ? .horizontal : .vertical
                (dx, dy) = (s.pending.dx, s.pending.dy)
            }
            switch s.axis {
            case .horizontal:
                s.tracker.push(-dx, at: time)
                world.scrollView(monitor: s.monitor, to: s.origin + s.tracker.position, config: config)
                queueTrackingLayout()
            case .vertical:
                s.tracker.push(-dy, at: time)
                followSwipe(&s)
            case nil:
                break
            }
            swipe = s
        case .ended(let time):
            guard var s = swipe else { return }
            s.tracker.push(0, at: time)
            switch s.axis {
            case .horizontal:
                settle(s)
            case .vertical:
                swipe = nil
                endVerticalSwipe(s)
            case nil:
                swipe = nil
            }
        case .momentum, .momentumEnded:
            // The release glide already owns the landing point; the system's free-scroll tail must not move it again.
            break
        case .wheel(let dx, let dy):
            let now = CACurrentMediaTime()
            if abs(dy) >= abs(dx) {
                guard now - lastWheel > 0.15 else { return }
                lastWheel = now
                run(dy < 0 ? .focusWorkspaceDown : .focusWorkspaceUp)
            } else {
                run(dx < 0 ? .focusColumnRight : .focusColumnLeft)
            }
        }
    }

    private func queueTrackingLayout() {
        guard !trackingLayoutQueued else { return }
        trackingLayoutQueued = true
        // Preserve every velocity sample, but present only the newest position when input arrives in a burst.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            trackingLayoutQueued = false
            guard swipe?.axis == .horizontal else { return }
            relayout(tracking: true)
        }
    }

    func settle(_ s: Swipe) {
        swipe = nil
        let before = world.focusedWindow
        let pos = world.viewPosition(monitor: s.monitor, config: config)
        world.endSwipe(monitor: s.monitor, coastingTo: pos + s.tracker.projectedEnd - s.tracker.position, config: config)
        relayout(fling: (-s.tracker.velocity, s.monitor))
        if world.focusedWindow != before && !overview { focusModel(layout: false) }
    }

    func swipeRange(_ start: Int, _ m: Int) -> (lo: Double, hi: Double) {
        let last = Double(world.monitors[m].workspaces.count - 1)
        return overview ? (0, last) : (max(0, Double(start) - 1), min(last, Double(start) + 1))
    }

    func followSwipe(_ s: inout Swipe) {
        let m = s.monitor
        guard world.monitors.indices.contains(m) else { return }
        if s.startIndex == nil {
            guard config.animations.spring(.workspaceSwitch) != nil, snapshots.allowed || mode.liveScenes,
                  let scene = scene(for: m), overview || scene.hasWallpaper else { return }
            s.startIndex = world.monitors[m].active
            if !scene.isVisible {
                let content = sceneContent(m, current: mode.liveScenes)
                scene.show(content, at: Double(world.monitors[m].active))
                refreshSnapshots(content.flatMap { $0.map(\.id) })
            }
            updateRing(at: CACurrentMediaTime())
        }
        guard let start = s.startIndex else { return }
        let (lo, hi) = swipeRange(start, m)
        scenes[world.monitors[m].id]?.track(RubberBand.workspaces.clamp(Double(start) + s.tracker.position / 300, lo, hi))
    }

    func endVerticalSwipe(_ s: Swipe) {
        let m = s.monitor
        guard world.monitors.indices.contains(m) else { return }
        guard let start = s.startIndex else {
            let steps = (s.tracker.projectedEnd / 300).rounded()
            guard steps != 0 else { return }
            world.focusedMonitor = m
            return run(steps > 0 ? .focusWorkspaceDown : .focusWorkspaceUp)
        }
        let (lo, hi) = swipeRange(start, m)
        let position = Double(start) + s.tracker.position / 300
        let velocity = s.tracker.velocity / 300 * RubberBand.workspaces.clampDerivative(position, lo, hi)
        let target = Int(min(max(Double(start) + s.tracker.projectedEnd / 300, lo), hi).rounded())
        if target == world.monitors[m].active {
            scenes[world.monitors[m].id]?.slide(to: target, velocity: velocity)
            return
        }
        let before = world.focusedWindow
        slideVelocity = velocity
        world.showWorkspace(monitor: m, index: target)
        relayout()
        if world.focusedWindow != before && !overview { focusModel() }
    }

    func window(at point: CGPoint) -> WindowID? {
        let floating = floatersShowingEverywhere().first { id in
            (applied[id] ?? wins[id]?.floatFrame)?.contains(point) == true
        }
        if let floating { return floating }
        let now = CACurrentMediaTime()
        return targets.keys.first { id in shownFrame(id, at: now)?.contains(point) == true }
    }

    func beginGrab(at point: CGPoint, resize: Bool) {
        guard !paused, !overview, let id = window(at: point), let win = wins[id] else { return }
        let frame = win.floating ? (win.floatFrame ?? applied[id] ?? .zero) : (applied[id] ?? .zero)
        if !win.floating {
            world.focus(id, config: config)
            motion.stop(id, at: nil)
        }
        grab = Grab(window: id, resize: resize, start: point, frame: frame, floating: win.floating, current: frame, point: point)
        focusWindow(id)
    }

    func moveGrab(to point: CGPoint) {
        guard var g = grab, let win = wins[g.window] else { return }
        g.point = point
        let dx = point.x - g.start.x, dy = point.y - g.start.y
        if g.resize {
            if g.floating {
                g.current = CGRect(x: g.frame.minX, y: g.frame.minY, width: max(100, g.frame.width + dx), height: max(60, g.frame.height + dy))
                win.floatFrame = g.current
                send(g.window, g.current)
            } else {
                world.perform(.setColumnWidth(.setFixed(max(100, g.frame.width + dx))), config: config)
                if let loc = world.locate(g.window), world.monitors[loc.monitor].workspaces[loc.workspace].columns[loc.column].tiles.count > 1 {
                    world.perform(.setWindowHeight(.setFixed(max(60, g.frame.height + dy))), config: config)
                }
                relayout(direct: true)
            }
        } else {
            g.current = g.frame.offsetBy(dx: dx, dy: dy).roundedToPoints
            send(id: g.window, g.current, verify: false)
            grab = g
            updateRing(at: CACurrentMediaTime())
            if g.floating {
                win.floatFrame = g.current
            } else if let m = world.monitors.firstIndex(where: { $0.screen.contains(point) }) {
                let area = world.monitors[m].area
                let local = CGPoint(x: point.x - area.minX, y: point.y - area.minY)
                let hint = insertHint(monitor: m, workspace: world.monitors[m].active, at: local)
                ring.showHint(hint.map { $0.offsetBy(dx: area.minX, dy: area.minY) }, below: win.windowID)
                g.edge = edge(g.edge, monitor: m, at: point)
            }
        }
        grab = g
        if g.edge != nil, edgeTimer == nil {
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.edgeScrollTick() }
        } else if g.edge == nil {
            edgeTimer?.invalidate()
            edgeTimer = nil
        }
    }

    private func edge(_ was: (monitor: Int, speed: Double, since: Double, last: Double)?, monitor m: Int, at point: CGPoint)
        -> (monitor: Int, speed: Double, since: Double, last: Double)? {
        let zone = 30.0, fastest = 1500.0, area = world.monitors[m].area
        let left = point.x - area.minX, right = area.maxX - point.x
        let speed: Double
        if left < zone { speed = -fastest * (1 - max(left, 0) / zone) }
        else if right < zone { speed = fastest * (1 - max(right, 0) / zone) }
        else { return nil }
        let now = CACurrentMediaTime()
        guard let was, was.monitor == m, (was.speed > 0) == (speed > 0) else { return (m, speed, now, now) }
        return (m, speed, was.since, was.last)
    }

    private func edgeScrollTick() {
        guard var g = grab, var e = g.edge else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        defer { e.last = now; g.edge = e; grab = g; moveGrab(to: g.point) }
        guard now - e.since >= 0.1 else { return }
        world.edgeScroll(monitor: e.monitor, by: e.speed * (now - e.last), config: config)
        relayout(direct: true)
    }

    func endGrab() {
        guard let g = grab else { return }
        grab = nil
        edgeTimer?.invalidate()
        edgeTimer = nil
        ring.showHint(nil, below: 0)
        if g.floating {
            if let win = wins[g.window] {
                win.floatFrame = g.current
                if let m = monitor(containing: g.current), let home = activeWorkspaceID(on: m) { win.floatHome = home }
            }
            send(g.window, g.current)
            return
        }
        if g.resize { return relayout() }
        let p = g.point
        guard let m = world.monitors.firstIndex(where: { $0.screen.contains(p) }) else { return relayout() }
        let area = world.monitors[m].area
        let local = CGPoint(x: p.x - area.minX, y: p.y - area.minY)
        let position = world.insertPosition(monitor: m, workspace: world.monitors[m].active, at: local, config: config)
        motion.stop(g.window, at: (g.current, m))
        world.move(g.window, to: m, workspace: world.monitors[m].active, at: position, config: config)
        relayout()
        focusModel()
    }

    func nativeDragEnded() {
        guard !dragged.isEmpty || !nativeMoving.isEmpty else { return }
        nativeMoving = []
        for (id, frame) in dragged {
            guard let win = wins[id], !win.floating, !win.suspended, let loc = world.locate(id) else { continue }
            if resizedByUser.contains(id) {
                world.adoptWidth(frame.width, for: id, config: config)
            } else if let m = monitor(containing: frame), m != loc.monitor {
                world.moveWindow(id, toMonitor: m, config: config)
            }
            motion.stop(id, at: (frame, loc.monitor))
            applied[id] = frame
        }
        dragged = [:]
        resizedByUser = []
        relayout()
    }

    func pointerMoved() {
        guard !paused else { return }
        let p = NSEvent.mouseLocation
        if let hot = config.hotCorner {
            let left = hot == .topLeft || hot == .bottomLeft, top = hot == .topLeft || hot == .topRight
            // The pointer stops a point short of a screen's right and top edges, so each side allows a point of slack.
            let corner = NSScreen.screens.contains { s in
                let f = s.frame
                return (left ? p.x <= f.minX + 1 : p.x >= f.maxX - 2) && (top ? p.y >= f.maxY - 2 : p.y <= f.minY + 1)
                    && f.insetBy(dx: -1, dy: -1).contains(p)
            }
            if corner && !inCorner { run(.toggleOverview) }
            inCorner = corner
        }
        if let limit = config.focusFollowsMouse { followMouse(limit) }
    }

    func followMouse(_ limit: Double) {
        guard grab == nil, swipe == nil, !overview, !recent.isOpen, NSEvent.pressedMouseButtons == 0,
              let id = window(at: pointer()), id != focused, let win = wins[id] else { return }
        if !win.floating, let loc = world.locate(id) {
            var trial = world
            let before = trial.viewPosition(monitor: loc.monitor, config: config)
            trial.focus(id, config: config)
            let moved = abs(trial.viewPosition(monitor: loc.monitor, config: config) - before)
            guard moved <= limit * world.monitors[loc.monitor].area.width + 1 else { return }
        }
        focusWindow(id)
    }

    func warpPointer(to id: WindowID) {
        guard config.warpMouseToFocus, grab == nil, let frame = targets[id]?.frame ?? wins[id]?.floatFrame else { return }
        let p = pointer()
        guard !frame.contains(p) else { return }
        let inner = frame.insetBy(dx: min(8, frame.width / 2), dy: min(8, frame.height / 2))
        CGWarpMouseCursorPosition(CGPoint(x: min(max(p.x, inner.minX), inner.maxX), y: min(max(p.y, inner.minY), inner.maxY)))
    }
}
