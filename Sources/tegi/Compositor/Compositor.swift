import AppKit
import QuartzCore
import TegiCore

/// Moves windows on a thread of its own, from the display's frame clock: each frame, every moving window's position goes
/// to the window server in one transaction. The main thread decides where windows go; nothing it does, from layout to
/// a slow app's Accessibility answer, can make a frame late. Sizes stay with the apps, which alone can redraw at one.
final class Compositor: NSObject {
    private let server: WindowServer
    private let lock = NSLock()
    private var thread: Thread!
    private var link: CADisplayLink?
    // Under the lock: what to present.
    private var world = World(monitors: [])
    private var windows: [WindowID: CGWindowID] = [:]
    private var flights: [WindowID: Flight] = [:]
    private var moves: [CGWindowID: CGPoint] = [:]
    /// Where each window was last put, so a late Accessibility write that pulled it elsewhere can be undone.
    private var origins: [WindowID: CGPoint] = [:]
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
            self.world = world
            self.windows = windows
        }
    }

    /// The flights to present. Springs are pure, so this thread and the main one agree on every frame.
    func fly(_ flights: [WindowID: Flight]) {
        lock.withLock { self.flights = flights }
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

    /// An app moved its window, or finished an Accessibility write that landed after the compositor moved it on.
    func reassert(_ id: WindowID) {
        lock.withLock {
            guard let window = windows[id], flights[id] == nil, let origin = origins[id] else { return }
            moves[window] = origin
        }
        wake()
    }

    /// The app put its window here itself, as it does while it resizes.
    func settled(_ id: WindowID, at origin: CGPoint) {
        lock.withLock { origins[id] = origin }
    }

    func endAll() {
        lock.withLock {
            flights = [:]
            moves = [:]
        }
    }

    /// Where the compositor last put a window, for `tegi msg state`.
    func origin(of id: WindowID) -> CGPoint? { lock.withLock { origins[id] } }

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
        lock.lock()
        if !flights.isEmpty {
            if let lastFrame, t - lastFrame > duration * 1.5 { missed += 1 }
            presented += 1
            lastFrame = t
        } else {
            lastFrame = nil
        }
        var batch = moves
        moves = [:]
        for (id, flight) in flights {
            guard let window = windows[id], world.monitors.indices.contains(flight.monitor) else { continue }
            let done = flight.isDone(at: t)
            let screen = world.place((done ? flight.target : flight.frame(at: t)).roundedToPoints, on: flight.monitor).frame
            if origins[id] != screen.origin {
                batch[window] = screen.origin
                origins[id] = screen.origin
            }
            if done { flights[id] = nil }
        }
        if !batch.isEmpty { server.submit(batch) }
        let idle = flights.isEmpty && moves.isEmpty
        lock.unlock()
        return idle
    }
}
