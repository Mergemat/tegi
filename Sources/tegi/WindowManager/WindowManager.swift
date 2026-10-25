import AppKit
import QuartzCore
import TegiCore

final class Win {
    let id: WindowID
    let element: AXUIElement
    let worker: AppWorker
    let windowID: CGWindowID
    let tileable: Bool
    let original: CGRect?
    var title: String
    var floating: Bool
    var suspended: Bool
    var floatHome: Int?
    var floatFrame: CGRect?

    init(id: WindowID, element: AXUIElement, worker: AppWorker, info: WindowInfo, floating: Bool) {
        self.id = id
        self.element = element
        self.worker = worker
        windowID = info.windowID
        tileable = info.tileable
        original = info.frame
        title = info.title
        self.floating = floating
        suspended = info.minimized || info.fullscreen
        floatFrame = info.frame
    }
}

final class WindowManager {
    var world = World(monitors: [])
    var config: Config
    var paused = false
    var onChange: () -> Void = {}
    var onHotkeyOverlay: () -> Void = {}
    var onSettings: (String?) -> Void = { _ in }
    var onQuit: () -> Void = {}

    var workers: [pid_t: AppWorker] = [:]
    var wins: [WindowID: Win] = [:]
    var ids: [AXUIElement: WindowID] = [:]
    var nextID = 1
    var applied: [WindowID: CGRect] = [:]
    /// Sizes apps kept when asked for another, so what tegi draws around a window matches it.
    var refusals: [WindowID: Refusal] = [:]
    var drift: [WindowID: Drift] = [:]
    var strays: [WindowID: DispatchWorkItem] = [:]
    var activating: (id: WindowID, since: CFTimeInterval)?
    var lastFocusMove = 0.0
    var leftBehind: Set<WindowID> = []

    var generation: [WindowID: Int] = [:]
    var unlanded: Set<WindowID> = []
    var hideWhenLanded: Set<UInt32> = []
    var sceneFinishes: [UInt32: Int] = [:]
    var verified: Set<WindowID> = []
    var floatHidden: Set<WindowID> = []
    var focused: WindowID? {
        // A window's picture is freshest as you leave it, which beats capturing it every second while you work in it.
        // It's taken once things are still: a capture while apps trade focus can stall the window server for half a second.
        didSet {
            if let old = oldValue, old != focused, wins[old] != nil {
                leftBehind.insert(old)
                scheduleWarmup()
            }
        }
    }
    // macOS echoes focus changes, sometimes late; while tegi moves focus, other echoes are stale.
    var pendingFocus: (id: WindowID?, until: Date)?
    var dragged: [WindowID: CGRect] = [:]
    var resizedByUser: Set<WindowID> = []

    let motion = Motion()
    var targets: [WindowID: Placement] = [:]
    var lastViews: [Double] = []
    var pressed: CFTimeInterval?
    var sentSomething = false
    var latency: String?
    var smoothness: String?
    var timing: String? {
        let parts = [latency, smoothness].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    let snapshots = Snapshots()
    var scenes: [UInt32: Scene] = [:]
    var shown: [UInt32: (id: Int, index: Int)] = [:]
    var overview = false
    var slideVelocity: Double?
    var wallpapers: [UInt32: IOSurface] = [:]
    var papers: [UInt32: IOSurface] = [:]
    var warmup: DispatchWorkItem?
    var freshener: Timer?
    var freshTicks = 0

    var input: InputTap?
    var swipe: Swipe?
    var grab: Grab?
    var edgeTimer: Timer?
    var lastWheel: CFTimeInterval = 0
    var inCorner = false
    var multitouch: Multitouch?

    let recent = RecentWindows()
    let ring = FocusRing()
    var observers: [NSObjectProtocol] = []
    var monitors: [Any] = []

    var canCapture: Bool { snapshots.allowed }

    init(config: Config) {
        self.config = config
    }

    func start() {
        applyConfigToWorld()
        world.setDisplays(displays(), config: config)
        world.nameWorkspaces(config.workspaces)
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.add(app, initial: false) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.remove(app.processIdentifier) }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let worker = self?.workers[app.processIdentifier] else { return }
                worker.focusedWindow { el in if let el { self?.focusChanged(el, worker) } }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.displaysChanged()
            },
        ]
        startInput()
        recent.onCommit = { [weak self] id in self?.focusWindow(id) }
        ring.onPickTab = { [weak self] id in self?.focusWindow(id) }
        for app in NSWorkspace.shared.runningApplications { add(app, initial: true) }
        startScenes()
        for command in config.startup { run(command) }
    }

    func applyConfigToWorld() {
        world.emptyWorkspaceAboveFirst = config.emptyWorkspaceAboveFirst
    }

    func displaysChanged() {
        swipe = nil
        if grab != nil { endGrab() }
        let wasOverview = overview
        overview = false
        world.setDisplays(displays(), config: config)
        world.nameWorkspaces(config.workspaces)
        motion.cancel()
        rebuildScenes()
        refreshWallpapers()
        relayout()
        if wasOverview { setOverview(true) }
    }

    func run(_ command: Command) {
        guard !paused || command == .quit else { return }
        let start = CFAbsoluteTimeGetCurrent()
        if recent.isOpen && recent.handle(command, binds: config.binds) { return }
        if let id = focused, let win = wins[id], win.floating, runFloating(command, win) { return }
        switch command {
        case .toggleWindowFloating: return toggleFloating()
        case .moveWindowToFloating: return setFocusedFloating(true)
        case .moveWindowToTiling: return setFocusedFloating(false)
        case .focusFloating: return focusFloating()
        case .focusTiling: return focusModel()
        case .switchFocusBetweenFloatingAndTiling:
            return focused.flatMap { wins[$0] }?.floating == true ? focusModel() : focusFloating()
        case .focusWindowPrevious:
            if let id = recent.previous(than: focused, among: Set(wins.keys)) { focusWindow(id) }
            return
        case .nextWindow(let sameApp), .previousWindow(let sameApp):
            return openSwitcher(forward: command == .nextWindow(sameApp: sameApp), sameApp: sameApp)
        case .closeWindow:
            if let id = focused, let win = wins[id] { win.worker.close(win.element) }
            return
        case .showHotkeyOverlay: return onHotkeyOverlay()
        case .showSettings(let pane): return onSettings(pane)
        case .toggleOverview: return setOverview(!overview)
        case .openOverview: return setOverview(true)
        case .closeOverview: return setOverview(false)
        case .spawn(let args) where args.count == 3 && args[0] == "open" && args[1] == "-b": return openApp(args[2])
        case .spawn(let args): return spawn(args)
        case .spawnSh(let line): return spawn(["/bin/sh", "-c", line])
        case .quit: return onQuit()
        default: break
        }
        let before = world.focusedWindow
        world.perform(command, config: config)
        if world.focusedWindow != before && !overview { lastFocusMove = CACurrentMediaTime() }
        relayout(measuringFrom: start)
        if world.focusedWindow != before && !overview { focusModel(layout: false) }
    }

    /// What `open -b` does, without its process and LaunchServices round trip: a window tegi already holds is focused at once.
    func openApp(_ bundleID: String) {
        // A hidden or minimized app needs macOS to bring it back, so those take the slow way.
        let mine = wins.values.filter { $0.worker.bundleID == bundleID && !$0.suspended }
            .filter { NSRunningApplication(processIdentifier: $0.worker.pid)?.isHidden != true }.map(\.id)
        if let id = recent.ordered(mine).first { return focusWindow(id) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return spawn(["open", "-b", bundleID]) }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func spawn(_ args: [String]) {
        guard let first = args.first else { return }
        let p = Process()
        if first.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: first)
            p.arguments = Array(args.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = args
        }
        p.environment = ProcessInfo.processInfo.environment
        try? p.run()
    }

    func update(_ new: Config) {
        let old = config
        config = new
        applyConfigToWorld()
        for win in wins.values {
            let app = win.worker.bundleID
            let was = old.rule(app: app, title: win.title).floating
            let now = new.rule(app: app, title: win.title).floating
            if was != now { setFloating(win, now ?? !win.tileable) }
        }
        if old.swipeModifier != new.swipeModifier || old.threeFingerSwipe != new.threeFingerSwipe { startInput() }
        world.setDisplays(displays(), config: config)
        world.nameWorkspaces(config.workspaces)
        let wasOverview = overview
        overview = false
        rebuildScenes()
        relayout()
        if wasOverview { setOverview(true) }
    }

    func setPaused(_ pause: Bool) {
        guard pause != paused else { return }
        if pause {
            restore(wait: false)
            paused = true
            ring.update([], tabs: [], config: config)
        } else {
            paused = false
            applied = [:]
            floatHidden = []
            relayout()
        }
        onChange()
    }

    func rule(_ win: Win) -> WindowRule { config.rule(app: win.worker.bundleID, title: win.title) }

    func restore(wait: Bool = true) {
        let group = DispatchGroup()
        var cascade = 0
        let hidden = world.layout(config: config).filter { !$0.value.visible }.map(\.key) + Array(floatHidden)
        for id in hidden.sorted() {
            guard let win = wins[id] else { continue }
            let m = world.locate(id)?.monitor ?? floatMonitor(win) ?? 0
            guard world.monitors.indices.contains(m) else { continue }
            let area = world.monitors[m].area
            let size = applied[id]?.size ?? win.original?.size ?? CGSize(width: 800, height: 600)
            var frame: CGRect
            if win.floating, let f = win.floatFrame {
                frame = f
            } else if let o = win.original, area.intersection(o).width * area.intersection(o).height > o.width * o.height / 2 {
                frame = o
            } else {
                let step = Double(cascade % 10) * 28 + config.gap
                cascade += 1
                frame = CGRect(x: area.minX + step, y: area.minY + step,
                               width: min(size.width, area.width * 0.7), height: min(size.height, area.height * 0.7))
            }
            win.worker.apply(id, win.element, frame, resize: true, measured: { _, _ in }, done: {})
        }
        guard wait else { return }
        for worker in workers.values { worker.flush(group) }
        _ = group.wait(timeout: .now() + 2)
    }

    func relayout(measuringFrom start: CFAbsoluteTime? = nil, direct: Bool = false,
                  fling: (velocity: Double, monitor: Int)? = nil) {
        guard !paused else { return }
        if let start { pressed = start }
        sentSomething = false
        defer {
            if !sentSomething && !motion.isMoving { pressed = nil }
        }
        world.pinned = Set(wins.values.compactMap { $0.floating && !$0.suspended ? $0.floatHome : nil })
        let placements = world.layout(config: config)
        let now = max(CACurrentMediaTime(), motion.clock)
        // Apps take different times to move a window; holding the quicker ones back keeps the strip in one piece.
        let slowest = placements.keys.compactMap { wins[$0]?.worker.lag }.max() ?? 0
        let animate = !direct && config.animations.on && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        followWorkspaces(animate: animate)
        let views = world.monitors.indices.map { world.viewPosition(monitor: $0, config: config) }
        defer { lastViews = views }
        for (id, p) in placements {
            guard wins[id] != nil, grab?.window != id || grab?.resize == true else { continue }
            if animate, let to = p.strip, let from = motion.current(id, at: now), from.monitor == p.monitor,
               let springs = springs(from: from.frame, to: to, monitor: p.monitor, views: views),
               motion.move(id, from: from.frame, to: to, monitor: p.monitor, at: now,
                           velocity: fling.flatMap { $0.monitor == p.monitor ? $0.velocity : nil },
                           delay: min(0.06, slowest - (wins[id]?.worker.lag ?? slowest)), springs: springs) {
                continue
            }
            motion.stop(id, at: p.strip.map { ($0, p.monitor) })
            send(id, p.frame)
        }
        motion.forget { placements[$0] == nil }
        placeFloating()
        if motion.isMoving {
            tick(at: now)
            motion.run { [weak self] t in self?.tick(at: t) }
        }
        targets = placements
        updateRing(at: now)
        onChange()
    }

    func springs(from: CGRect, to: CGRect, monitor: Int, views: [Double]) -> Motion.Springs? {
        let a = config.animations
        let scrolled = lastViews.indices.contains(monitor) && views.indices.contains(monitor)
            && abs((from.minX + lastViews[monitor]) - (to.minX + views[monitor])) < 1 && from.minY == to.minY
        guard let position = a.spring(scrolled ? .horizontalViewMovement : .windowMovement) else { return nil }
        let resized = from.size != to.size
        guard let size = resized ? a.spring(.windowResize) : position else { return nil }
        return Motion.Springs(position: position, size: size, slowdown: a.slowdown)
    }

    func tick(at now: CFTimeInterval) {
        guard !paused else { return motion.cancel() }
        for f in motion.frames(at: now)
            where world.monitors.indices.contains(f.monitor) {
            send(id: f.id, world.place(f.frame, on: f.monitor).frame, verify: f.last)
        }
        updateRing(at: now)
        if !motion.isMoving, let summary = motion.summary() {
            smoothness = summary
            onChange()
            scheduleWarmup()
        }
    }

    func send(_ id: WindowID, _ frame: CGRect) { send(id: id, frame, verify: true) }

    func send(id: WindowID, _ frame: CGRect, verify: Bool) {
        guard let win = wins[id], applied[id] != frame || verify && !verified.contains(id) else { return }
        let resize = applied[id]?.size != frame.size || verify && !verified.contains(id)
        applied[id] = frame
        if verify { verified.insert(id) } else if resize { verified.remove(id) }
        motion.sent(id, app: win.worker.name)
        sentSomething = true
        let gen = (generation[id] ?? 0) + 1
        generation[id] = gen
        unlanded.insert(id)
        win.worker.apply(id, win.element, frame, resize: resize, verify: verify, measured: { [weak self] id, size in
            guard let self else { return }
            refusals[id] = abs(size.height - frame.height) > 1 ? Refusal(asked: frame.size, got: size) : nil
            if abs(size.width - frame.width) > 1 { appRefused(width: size.width, for: id) }
        }, done: { [weak self] in
            self?.placed(id, generation: gen)
        })
    }

    func onScreen(_ wid: CGWindowID) -> CGRect? {
        // The window server wants raw window numbers, not CFNumbers.
        var ids = [UnsafeRawPointer(bitPattern: UInt(wid))]
        guard let array = CFArrayCreate(nil, &ids, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    func shownFrame(_ id: WindowID, at now: CFTimeInterval) -> CGRect? {
        if let g = grab, g.window == id, !g.resize, !g.floating { return g.current }
        let moving = motion.current(id, at: now)
        let p = moving.map { world.place($0.frame.roundedToPoints, on: $0.monitor) } ?? targets[id]
        guard p?.visible == true, var frame = p?.frame else { return nil }
        // Mid-motion the ring follows the window as the window server shows it: apps apply tegi's orders a few frames
        // late, and report them done before they're on screen, so either would leave the ring around empty space.
        if motion.isFlying(id), let wid = wins[id]?.windowID {
            guard let at = onScreen(wid), world.monitors.contains(where: { $0.screen.intersection(at).width > 40 }) else { return nil }
            frame = at
        }
        return refusals[id]?.apply(to: frame) ?? frame
    }

    /// What the ring and pictures round a window's corners by: a set radius, else the window's own, else macOS's usual.
    func cornerRadius(_ id: WindowID) -> Double { config.windowCornerRadius ?? snapshots.radii[id] ?? 16 }

    func updateRing(at now: CFTimeInterval) {
        let floatingFocused = focused.flatMap { wins[$0] }?.floating == true
        var tabs: [FocusRing.Tabs] = []
        let rings = world.monitors.enumerated().map { m, mon -> FocusRing.Target in
            let ws = mon.workspaces[mon.active]
            func shown(_ id: WindowID) -> CGRect? { shownFrame(id, at: now) }
            // Not hidden under a picture: hiding a window lands a frame before the picture shows, so they'd blink.
            for col in ws.columns where col.tabbed && col.tiles.count > 1 && !col.fullscreen {
                if let frame = shown(col.activeWindow) { tabs.append(.init(display: mon.id, frame: frame, windows: col.windows, active: col.active)) }
            }
            var frame: CGRect?
            if let id = ws.activeWindow, !ws.columns[ws.active].fullscreen, !(m == world.focusedMonitor && floatingFocused) {
                frame = shown(id)
            }
            return FocusRing.Target(display: mon.id, screen: mon.screen, frame: frame, active: m == world.focusedMonitor,
                                    radius: ws.activeWindow.map(cornerRadius) ?? 0)
        }
        ring.update(rings, tabs: tabs, config: config)
    }

    func placed(_ id: WindowID, generation gen: Int) {
        if generation[id] == gen {
            unlanded.remove(id)
            if !hideWhenLanded.isEmpty { hideLandedScenes() }
        }
        if let start = pressed {
            pressed = nil
            latency = String(format: "Keypress to first motion: %.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000)
            onChange()
        }
        motion.landed(id)
    }

    func appRefused(width: Double, for id: WindowID) {
        guard let win = wins[id], !win.floating, !win.suspended, grab?.window != id else { return }
        world.adoptWidth(width, for: id, config: config)
        applied[id]?.size.width = width
        relayout()
    }

    func add(_ app: NSRunningApplication, initial: Bool) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), workers[pid] == nil else { return }
        let worker = AppWorker(app) { [weak self] worker, el, event in self?.handle(worker, el, event) }
        workers[pid] = worker
        worker.start { [weak self] found in
            guard let self else { return }
            for (el, info) in found.sorted(by: { ($0.1.frame?.minX ?? 0) < ($1.1.frame?.minX ?? 0) }) {
                track(el, info, worker, initial: initial)
            }
            relayout()
            if app.isActive { worker.focusedWindow { el in if let el { self.focusChanged(el, worker) } } }
        }
    }

    func remove(_ pid: pid_t) {
        guard workers.removeValue(forKey: pid) != nil else { return }
        let wasFocused = world.focusedWindow
        for win in wins.values where win.worker.pid == pid { forget(win.id) }
        relayout()
        if world.focusedWindow != wasFocused { focusModel() }
    }

    func track(_ el: AXUIElement, _ info: WindowInfo, _ worker: AppWorker, initial: Bool) {
        guard ids[el] == nil, info.tileable || info.floatable else { return }
        let id = nextID
        nextID += 1
        var rule = config.rule(app: worker.bundleID, title: info.title)
        let win = Win(id: id, element: el, worker: worker, info: info, floating: rule.floating ?? !info.tileable)
        wins[id] = win
        ids[el] = id
        worker.watch(el)
        if win.floating {
            win.floatHome = floatTarget(rule)
            return
        }
        guard !win.suspended else { return }
        if initial {
            world.adopt(id, monitor: monitor(containing: info.frame), config: config)
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == worker.pid
            rule.focused = rule.focused != false && frontmost
            world.insert(id, rule: rule, config: config)
            if rule.focused == false && frontmost { focusModel() }
        }
    }

    func forget(_ id: WindowID) {
        guard let win = wins.removeValue(forKey: id) else { return }
        ids[win.element] = nil
        applied[id] = nil
        refusals[id] = nil
        drift[id] = nil
        strays.removeValue(forKey: id)?.cancel()
        verified.remove(id)
        floatHidden.remove(id)
        leftBehind.remove(id)
        generation[id] = nil
        unlanded.remove(id)
        dragged[id] = nil
        world.remove(id, config: config)
        if focused == id { focused = nil }
        recent.forget(id)
        snapshots.forget(id)
    }

    func handle(_ worker: AppWorker, _ el: AXUIElement, _ event: AppWorker.Event) {
        if event == .created {
            worker.read(el) { [weak self] info in
                guard let self, let info else { return }
                track(el, info, worker, initial: false)
                relayout()
            }
            return
        }
        if event == .focused { return focusChanged(el, worker) }
        guard let id = ids[el], let win = wins[id] else { return }
        switch event {
        case .destroyed:
            let wasFocused = world.focusedWindow == id || focused == id
            forget(id)
            relayout()
            if wasFocused { focusModel() }
        case .retitled:
            worker.read(el) { [weak self] info in
                guard let info, self?.wins[id] != nil else { return }
                win.title = info.title
                self?.onChange()
            }
        case .minimized:
            suspend(win, true)
        case .restored:
            suspend(win, false)
        case .moved, .resized:
            if win.floating { return floatingMoved(win) }
            let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
            guard grab?.window != id else { return }
            // tegi's own moves echo back every frame; reading each one would double the traffic to the app mid-motion.
            if !mouseDown, motion.isFlying(id) || unlanded.contains(id) { return putBack(id, worker: worker, el: el) }
            worker.read(el) { [weak self] info in
                guard let self, let info, wins[id] != nil else { return }
                if info.fullscreen != win.suspended && !info.minimized { return suspend(win, info.fullscreen) }
                guard let frame = info.frame, let laidOut = applied[id], frame != laidOut else { return }
                if mouseDown {
                    dragged[id] = frame
                    if event == .resized && frame.size != laidOut.size { resizedByUser.insert(id) }
                    return
                }
                putBack(id, worker: worker, el: el)
            }
        case .created, .focused:
            break
        }
    }

    /// An app moved its own tiled window, often restoring a saved frame right after it opens: tegi puts it back.
    func putBack(_ id: WindowID, worker: AppWorker, el: AXUIElement) {
        // tegi's own frames can report late, so only a window that is still off once things have settled is the app's doing.
        strays[id]?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, wins[id] != nil else { return }
            guard !unlanded.contains(id), !motion.isMoving else { return putBack(id, worker: worker, el: el) }
            let gen = generation[id]
            worker.read(el) { [weak self] info in
                // Off screen, macOS keeps a hidden window's sliver its own way.
                guard let self, generation[id] == gen, targets[id]?.visible == true, let frame = info?.frame, let laidOut = applied[id],
                      Drift.strayed(frame, from: laidOut, refusal: refusals[id]),
                      drift[id, default: Drift()].allow(at: CACurrentMediaTime()) else { return }
                // One plain move and resize: the verifying path sets the size twice, which shows as a twitch.
                applied[id] = nil
                send(id: id, laidOut, verify: false)
            }
        }
        strays[id] = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: check)
    }

    func suspend(_ win: Win, _ suspended: Bool) {
        guard win.suspended != suspended else { return }
        win.suspended = suspended
        applied[win.id] = nil
        if win.floating {
            floatHidden.remove(win.id)
        } else if suspended {
            world.remove(win.id, config: config)
        } else {
            world.insert(win.id, rule: rule(win), config: config)
        }
        relayout()
    }

    func focusChanged(_ el: AXUIElement, _ worker: AppWorker) {
        guard let id = ids[el] else {
            // Some apps announce a window before it has a role; it has one by the time it takes focus.
            worker.read(el) { [weak self] info in
                guard let self, let info, ids[el] == nil else { return }
                track(el, info, worker, initial: false)
                relayout()
            }
            return
        }
        if let p = pendingFocus, Date() < p.until {
            guard p.id == id else { return }
            pendingFocus = nil
        }
        focused = id
        recent.focused(id)
        guard let win = wins[id] else { return }
        if win.floating, let home = win.floatHome, let (m, w) = world.find(workspace: home), world.monitors[m].active != w {
            world.showWorkspace(monitor: m, index: w)
        } else if !win.floating && !win.suspended && world.focusedWindow != id {
            world.focus(id, config: config)
        }
        relayout()
    }

    func focusWindow(_ id: WindowID) {
        guard let win = wins[id] else { return }
        if win.floating {
            if let home = win.floatHome, let (m, w) = world.find(workspace: home) { world.showWorkspace(monitor: m, index: w) }
            focused = id
            expectFocus(id)
            recent.focused(id)
            relayout()
            win.worker.focus(win.element)
            return
        }
        world.focus(id, config: config)
        relayout()
        focusModel()
    }

    func focusModel(layout: Bool = true) {
        guard let id = world.focusedWindow, let win = wins[id] else {
            if let floater = floatersShowing(on: world.focusedMonitor).first { return focusWindow(floater) }
            focused = nil
            expectFocus(nil)
            // tegi's own main thread answers this, so it can't be asked from there.
            DispatchQueue.global(qos: .userInteractive).async {
                AXUIElementCreateApplication(getpid()).set(kAXFrontmostAttribute, kCFBooleanTrue)
            }
            relayout()
            return
        }
        focused = id
        expectFocus(id)
        recent.focused(id)
        activate(win)
        if layout { relayout() }
        warpPointer(to: id)
    }

    /// One activation at a time: an app takes tens of milliseconds to come forward, so with keys held down the next one
    /// goes straight to wherever focus is by then instead of working through a backlog. A hung app holds it up briefly.
    func activate(_ win: Win) {
        let now = CACurrentMediaTime()
        if let a = activating, now - a.since < 0.25 { return }
        activating = (win.id, now)
        win.worker.focus(win.element) { [weak self] in
            guard let self else { return }
            activating = nil
            if let id = focused, id != win.id, let next = wins[id], !next.floating { activate(next) }
        }
    }

    func expectFocus(_ id: WindowID?) {
        let until = Date() + 0.5
        pendingFocus = (id, until)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, let p = pendingFocus, p.until == until else { return }
            pendingFocus = nil
            syncFocus()
        }
    }

    func syncFocus() {
        guard let app = NSWorkspace.shared.frontmostApplication, let worker = workers[app.processIdentifier] else { return }
        worker.focusedWindow { [weak self] el in if let el { self?.focusChanged(el, worker) } }
    }

    func state() -> [String: Any] {
        let placements = world.layout(config: config)
        func window(_ id: WindowID) -> [String: Any] {
            guard let win = wins[id] else { return ["id": id] }
            var out: [String: Any] = ["id": id, "app": win.worker.name, "bundle_id": win.worker.bundleID ?? NSNull(),
                                      "title": win.title, "floating": win.floating, "focused": focused == id]
            if let p = placements[id] {
                out["frame"] = [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height]
                out["visible"] = p.visible
            } else if let f = win.floatFrame {
                out["frame"] = [f.minX, f.minY, f.width, f.height]
                out["visible"] = !floatHidden.contains(id)
            }
            if let home = win.floatHome { out["workspace_id"] = home }
            return out
        }
        return [
            "timing": timing ?? NSNull(),
            "paused": paused,
            "focused_monitor": world.focusedMonitor,
            "monitors": world.monitors.map { mon in
                [
                    "id": mon.id,
                    "name": mon.name,
                    "area": [mon.area.minX, mon.area.minY, mon.area.width, mon.area.height],
                    "active_workspace": mon.active,
                    "workspaces": mon.workspaces.map { ws in
                        ["id": ws.id, "name": ws.name ?? NSNull(), "active_column": ws.active,
                         "columns": ws.columns.map { $0.windows.map(window) }] as [String: Any]
                    },
                ] as [String: Any]
            },
            "floating": wins.values.filter(\.floating).map { window($0.id) },
        ]
    }

    func monitor(containing frame: CGRect?) -> Int? {
        guard let frame else { return nil }
        return world.monitors.firstIndex { $0.screen.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    func displays() -> [Display] {
        guard let main = NSScreen.screens.first else { return [] }
        let h = main.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { s in
            Display(id: s.displayID, name: s.localizedName, screen: flip(s.frame), area: config.struts.inset(flip(s.visibleFrame)))
        }
    }

    func pointer() -> CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    func pointerMonitor() -> Int? {
        let p = pointer()
        return world.monitors.firstIndex { $0.screen.contains(p) }
    }
}

extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }
}
