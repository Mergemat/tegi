import AppKit
import QuartzCore
import TegiCore

/// Presents window motion on a thread of its own, from the display's frame clock. Each frame, every moving window's
/// position goes to the window server in one transaction, and the pictures standing in for resizing windows move in
/// the same frame. The main thread decides where windows go; nothing it does, from layout to a slow app's
/// Accessibility answer, can make a frame late.
final class Compositor: NSObject {
    /// A window resizing on screen: a live picture stands in while the real window, out of sight, takes its new size.
    /// While it moves, the app draws at the larger of the old and new size on each side, so the picture only ever
    /// clips what's drawn, never stretches it: a growing side opens onto the new layout, a shrinking one slides shut
    /// over the old. Landed, the app takes its final size, and the real window comes back exactly as the picture was.
    struct StandIn {
        enum Phase: Equatable {
            /// The picture is up over the real window, which hides once the picture has had time to show.
            case covering(frames: Int)
            /// The app was asked for room to draw in, and hasn't taken it yet.
            case makingRoom(Ask)
            case moving
            /// Landed; the app was asked for its final size.
            case finishing(Ask)
            case done
        }

        struct Ask: Equatable {
            var frame: CGRect
            var at: CFTimeInterval
            var before: CGSize
            var answered = false

            /// The app took the frame once its window's size changes. One that keeps its size says so only by
            /// answering, and one that never answers isn't waited on.
            func taken(drawn: CGSize, at t: CFTimeInterval) -> Bool {
                abs(drawn.width - before.width) > 0.5 || abs(drawn.height - before.height) > 0.5
                    || answered && t - at > 0.05 || t - at > 0.25
            }
        }

        let panel: StandIns
        let window: CGWindowID
        let monitor: Int
        var size: ResizeFrames
        var shown: CGRect
        /// What the app's picture of the window measures, as the window server has the window.
        var drawn: CGSize
        var phase = Phase.covering(frames: 0)
        /// When the size starts to spring: once the app draws at a size the picture can clip to.
        var ready: CFTimeInterval?
        var landed = false

        var hidden: Bool { if case .covering = phase { false } else { true } }

        /// Room for every frame between where the picture is and where it's going.
        var room: CGSize { CGSize(width: max(shown.width, size.end.width), height: max(shown.height, size.end.height)) }
    }

    /// Main thread: tell the app this frame for its window. `final` asks are the layout's; the others only make room.
    var onAsk: (WindowID, CGRect, _ final: Bool) -> Void = { _, _, _ in }
    /// Main thread: the real window is back where the layout put it, at the size the app took.
    var onSwapped: (WindowID, _ target: CGRect, _ took: CGSize) -> Void = { _, _, _ in }

    private let server: WindowServer
    private let lock = NSLock()
    private var thread: Thread!
    private var link: CADisplayLink?
    // Under the lock: what to present.
    private var world = World(monitors: [])
    private var windows: [WindowID: CGWindowID] = [:]
    private var flights: [WindowID: Flight] = [:]
    private var standIns: [WindowID: StandIn] = [:]
    private var moves: [CGWindowID: CGPoint] = [:]
    /// Where each window was last put, so a late Accessibility write that pulled it elsewhere can be undone.
    private var origins: [WindowID: CGPoint] = [:]
    /// Panels whose pictures linger a couple of frames after their windows came back.
    private var retiring: [ObjectIdentifier: StandIns] = [:]
    /// Every panel a picture went up in, so none is left showing one that no resize owns.
    private var panels: [ObjectIdentifier: StandIns] = [:]
    private var lastFrame: CFTimeInterval?
    private var presented = 0, missed = 0
    /// Frames presented while something moved, and how many came a vsync or more late.
    var frames: (presented: Int, missed: Int) { lock.withLock { (presented, missed) } }

    init(server: WindowServer) {
        self.server = server
        super.init()
        let started = DispatchSemaphore(value: 0)
        thread = Thread {
            // A port keeps the run loop alive between animations, while the display link is paused.
            RunLoop.current.add(NSMachPort(), forMode: .common)
            started.signal()
            RunLoop.current.run()
        }
        thread.name = "tegi compositor"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        // NSScreen belongs to the main thread; the link it makes can tick on any run loop.
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(step)) else { return }
        link.isPaused = true
        self.link = link
        perform(#selector(attach), on: thread, with: nil, waitUntilDone: true)
    }

    @objc private func attach() { link?.add(to: .current, forMode: .common) }

    // MARK: Main thread

    func update(world: World, windows: [WindowID: CGWindowID]) {
        lock.withLock {
            // A window hidden behind its picture always comes back, even one tegi stops managing mid-resize.
            for (id, s) in standIns where windows[id] == nil {
                swap(s)
                standIns[id] = nil
            }
            self.world = world
            self.windows = windows
        }
        wake()
    }

    /// Everything Motion is flying. Springs are pure, so this thread and the main one agree on every frame.
    func fly(_ flights: [WindowID: Flight]) {
        lock.withLock {
            // A resize lands later here than in Motion, its size waiting on the app, and finishes on its own.
            var all = flights
            for (id, f) in self.flights where standIns[id] != nil && all[id] == nil { all[id] = f }
            self.flights = all
        }
        wake()
    }

    /// A one-off move, presented with the next frame.
    func place(_ id: WindowID, at origin: CGPoint) {
        lock.withLock {
            guard let window = windows[id] else { return }
            origins[id] = origin
            moves[window] = origin
        }
        wake()
    }

    /// An app finished an Accessibility write, which can land after the compositor moved the window on.
    func reassert(_ id: WindowID) {
        lock.withLock {
            guard let window = windows[id], let origin = origins[id], standIns[id] == nil else { return }
            moves[window] = origin
        }
        wake()
    }

    /// Takes over a picture `panel` just put up for `window`.
    func beginStandIn(_ id: WindowID, window: CGWindowID, panel: StandIns, monitor: Int, size: ResizeFrames) {
        lock.withLock {
            panels[ObjectIdentifier(panel)] = panel
            panel.claim(window)
            standIns[id] = StandIn(panel: panel, window: window, monitor: monitor, size: size, shown: size.from, drawn: size.from.size)
        }
        wake()
    }

    /// A new target mid-flight: the picture carries on from where it is, and the app is asked for more room if it
    /// now needs it.
    func retargetStandIn(_ id: WindowID, to target: CGRect, accepted: CGSize?, flyingFrom start: CGRect?) {
        lock.withLock {
            guard var s = standIns[id], s.size.target != target else { return }
            s.size = ResizeFrames(from: s.shown, start: start ?? s.size.start, target: target, accepted: accepted)
            s.landed = false
            if s.hidden {
                s.phase = .moving
                s.ready = nil
            }
            standIns[id] = s
        }
        wake()
    }

    /// The app answered an ask for `frame`.
    func answered(_ id: WindowID, _ frame: CGRect) {
        lock.withLock {
            guard var s = standIns[id] else { return }
            switch s.phase {
            case .makingRoom(var ask) where ask.frame == frame:
                ask.answered = true
                s.phase = .makingRoom(ask)
            case .finishing(var ask) where ask.frame == frame:
                ask.answered = true
                s.phase = .finishing(ask)
            default:
                return
            }
            standIns[id] = s
        }
        wake()
    }

    func endStandIn(_ id: WindowID) {
        lock.withLock {
            guard let s = standIns.removeValue(forKey: id) else { return }
            if s.hidden { origins[id] = s.size.target.origin }
            swap(s)
        }
        wake()
    }

    func endAll() {
        lock.withLock {
            for s in standIns.values { swap(s) }
            standIns = [:]
            flights = [:]
            moves = [:]
        }
        wake()
    }

    /// Where the compositor last put a window, for `tegi msg state`.
    func origin(of id: WindowID) -> CGPoint? { lock.withLock { origins[id] } }

    func standIn(_ id: WindowID) -> (shown: CGRect, target: CGRect)? {
        lock.withLock { standIns[id].map { ($0.shown, $0.size.target) } }
    }

    // MARK: Compositor thread

    private func wake() {
        perform(#selector(resume), on: thread, with: nil, waitUntilDone: false)
    }

    /// A paused link's first frame comes up to two vsyncs after the key that started the motion; this one goes now.
    @objc private func resume() {
        guard let link, link.isPaused else { return }
        link.isPaused = false
        present(at: CACurrentMediaTime() + link.duration, frame: link.duration)
    }

    @objc private func step(_ link: CADisplayLink) {
        if present(at: link.targetTimestamp, frame: link.duration) { link.isPaused = true }
    }

    /// Returns whether there's nothing left to present.
    @discardableResult private func present(at t: CFTimeInterval, frame duration: CFTimeInterval) -> Bool {
        var asks: [(WindowID, CGRect, Bool)] = []
        var swapped: [(WindowID, CGRect, CGSize)] = []
        var swaps: [StandIn] = []
        lock.lock()
        if !flights.isEmpty || !standIns.isEmpty {
            if let lastFrame, t - lastFrame > duration * 1.5 { missed += 1 }
            presented += 1
            lastFrame = t
        } else {
            lastFrame = nil
        }
        var batch = moves
        moves = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, flight) in flights {
            guard let window = windows[id], world.monitors.indices.contains(flight.monitor) else { continue }
            if var s = standIns[id] {
                // The size springs from when the app is ready, as if it had started then.
                let sizeAt = s.ready.map { t - max(0, $0 - flight.w.start) } ?? flight.w.start
                let done = flight.x.isDone(at: t) && flight.y.isDone(at: t) && flight.w.isDone(at: sizeAt) && flight.h.isDone(at: sizeAt)
                let strip = done ? flight.target : CGRect(x: flight.x.value(at: t), y: flight.y.value(at: t),
                                                          width: flight.w.value(at: sizeAt), height: flight.h.value(at: sizeAt))
                s.shown = s.size.frame(flying: world.place(strip.roundedToPoints, on: flight.monitor).frame)
                s.landed = done
                standIns[id] = s
                if done { flights[id] = nil }
                continue
            }
            let done = flight.isDone(at: t)
            let screen = world.place((done ? flight.target : flight.frame(at: t)).roundedToPoints, on: flight.monitor).frame
            if origins[id] != screen.origin {
                batch[window] = screen.origin
                origins[id] = screen.origin
            }
            if done { flights[id] = nil }
        }
        for (id, var s) in standIns {
            let window = s.window
            guard windows[id] != nil else {
                standIns[id] = nil
                swaps.append(s)
                continue
            }
            if flights[id] == nil { s.landed = true }
            if s.hidden, let bounds = server.bounds(window) { s.drawn = bounds.size }
            let screen = world.monitors.indices.contains(s.monitor) ? world.monitors[s.monitor].screen : s.size.target
            switch s.phase {
            case .covering(let frames) where frames < 2:
                // An existing panel shows a new picture within a frame; hiding after two keeps the spot from blinking.
                s.phase = .covering(frames: frames + 1)
            case .covering:
                server.hide(window)
                s.phase = .moving
                s.ready = nil
            case .makingRoom(let ask) where ask.taken(drawn: s.drawn, at: t):
                // It draws at the new size in the frame after it takes it. Room that was just the final size is the
                // app's answer for it, so the picture heads for what it took.
                if ask.frame.size == s.size.end { s.size.accepted = s.drawn }
                s.phase = .moving
                s.ready = t + duration
            case .moving where s.ready == nil:
                let room = s.room
                if s.drawn.width + 0.5 >= room.width && s.drawn.height + 0.5 >= room.height {
                    s.ready = t
                } else {
                    let frame = Self.fit(room, near: s.size.target, on: screen)
                    s.phase = .makingRoom(.init(frame: frame, at: t, before: s.drawn))
                    asks.append((id, frame, false))
                }
            case .moving where s.landed:
                if abs(s.drawn.width - s.size.end.width) <= 0.5 && abs(s.drawn.height - s.size.end.height) <= 0.5 {
                    s.size.accepted = s.drawn
                    s.phase = .done
                } else {
                    let frame = Self.fit(s.size.target.size, near: s.size.target, on: screen)
                    s.phase = .finishing(.init(frame: frame, at: t, before: s.drawn))
                    asks.append((id, frame, true))
                }
            case .finishing(let ask) where ask.taken(drawn: s.drawn, at: t):
                s.size.accepted = s.drawn
                s.phase = .done
            default:
                break
            }
            s.panel.move(window, to: s.phase == .done ? CGRect(origin: s.size.target.origin, size: s.drawn) : s.shown)
            standIns[id] = s
            if s.phase == .done {
                standIns[id] = nil
                origins[id] = s.size.target.origin
                swaps.append(s)
                swapped.append((id, s.size.target, s.drawn))
            }
        }
        CATransaction.commit()
        if !batch.isEmpty { server.submit(batch) }
        for s in swaps { swap(s) }
        // A picture no resize owns is taken down, whatever left it there.
        let owned = Set(standIns.values.map(\.window))
        for panel in panels.values where panel.retireAll(except: owned) { retiring[ObjectIdentifier(panel)] = panel }
        retiring = retiring.filter { $0.value.step() }
        let idle = flights.isEmpty && standIns.isEmpty && moves.isEmpty && retiring.isEmpty
        lock.unlock()
        if !asks.isEmpty || !swapped.isEmpty {
            DispatchQueue.main.async { [self] in
                for (id, frame, final) in asks { onAsk(id, frame, final) }
                for (id, target, took) in swapped { onSwapped(id, target, took) }
            }
        }
        return idle
    }

    /// Where to tell an app its out-of-sight window is: macOS fits a resize to the screen around where the app thinks
    /// its window is, so a size is asked for at a place it fits. The compositor puts the window back where it belongs.
    static func fit(_ size: CGSize, near frame: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - size.width)),
               y: max(screen.minY, min(frame.minY, screen.maxY - size.height)),
               width: size.width, height: size.height)
    }

    /// Under the lock. The real window comes back beneath its picture, exactly where it belongs: apps put windows
    /// asked to go off screen back on it, the compositor doesn't.
    private func swap(_ s: StandIn) {
        if s.hidden {
            server.submit([s.window: s.size.target.origin])
            server.show(s.window, below: s.panel.number)
        }
        s.panel.retire(s.window)
        retiring[ObjectIdentifier(s.panel)] = s.panel
    }
}

/// Where a resize picture is for where the flight is: the flight's corner, and a size as far from where the window
/// began to where the app will settle as the spring is from its start to its target.
struct ResizeFrames: Equatable {
    /// The window as it really showed, at the size it had taken.
    var from: CGRect
    /// Where the flight began; how far the spring has come is measured from it.
    var start: CGRect
    var target: CGRect
    /// The size the app takes for `target`: what it took when asked before, then what it takes now.
    var accepted: CGSize?

    var end: CGSize { accepted ?? target.size }

    func frame(flying f: CGRect) -> CGRect {
        func along(_ a: Double, _ b: Double, _ x: Double) -> Double? { abs(b - a) < 0.5 ? nil : (x - a) / (b - a) }
        let pw = along(start.width, target.width, f.width), ph = along(start.height, target.height, f.height)
        let moving = [pw, ph].compactMap { $0 }
        let progress = moving.isEmpty ? 1 : moving.reduce(0, +) / Double(moving.count)
        return CGRect(x: f.minX, y: f.minY,
                      width: from.width + (pw ?? progress) * (end.width - from.width),
                      height: from.height + (ph ?? progress) * (end.height - from.height))
    }
}
