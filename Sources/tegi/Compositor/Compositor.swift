import AppKit
import QuartzCore
import TegiCore

/// Publishes window presentations together on the display clock. App geometry updates cannot advance the animation.
final class Compositor: NSObject {
    private let server: WindowServer
    private let lock = NSLock()
    private var thread: Thread!
    private var link: CADisplayLink?
    // Under the lock: what to present.
    private var world = World(monitors: [])
    private var windows: [WindowID: CGWindowID] = [:]
    private var flights: [WindowID: Flight] = [:]
    private var moves: [CGWindowID: WindowServer.Presentation] = [:]
    private var shown: [WindowID: WindowServer.Presentation] = [:]
    private var lastFrame: CFTimeInterval?
    private var presented = 0, missed = 0
    private var notifying = false
    private var committedIdle = true
    var onCommit: (Bool) -> Void = { _ in }
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

    func update(world: World, windows: [WindowID: CGWindowID], excluded: Set<CGWindowID> = [], clips: [CGWindowID: CGRect] = [:], appOwned: Set<CGWindowID> = []) {
        lock.withLock {
            server.manage(Set(windows.values), excluding: excluded, clips: clips, appOwned: appOwned)
            let removed = Set(self.windows.keys).subtracting(windows.keys)
            for id in removed { shown[id] = nil; flights[id] = nil }
            moves = moves.filter { windows.values.contains($0.key) }
            self.world = world
            self.windows = windows
        }
    }

    /// The flights to present. Springs are pure, so this thread and the main one agree on every frame.
    func fly(_ flights: [WindowID: Flight]) {
        lock.withLock { self.flights = flights }
        wake()
    }

    /// An explicit clip separates an inactive workspace from a window just beyond its display's edge.
    func place(_ id: WindowID, frame: CGRect, clip: CGRect?) {
        lock.withLock {
            guard let window = windows[id] else { return }
            let presentation = WindowServer.Presentation(frame: frame, clip: clip)
            shown[id] = presentation
            moves[window] = presentation
        }
        wake()
    }

    func endAll() {
        lock.withLock {
            flights = [:]
            moves = [:]
            shown = [:]
            server.releaseAll()
        }
    }

    func release(_ id: WindowID) {
        lock.withLock {
            shown[id] = nil
            flights[id] = nil
            if let window = windows.removeValue(forKey: id) {
                moves[window] = nil
                server.release([window])
            }
        }
    }

    func origin(of id: WindowID) -> CGPoint? { lock.withLock { shown[id]?.frame.origin } }

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
            let frame = (done ? flight.target : flight.frame(at: t)).roundedToPoints
            let presentation = WindowServer.Presentation(frame: frame, clip: world.monitors[flight.monitor].screen, resizeTo: done ? nil : flight.target.size)
            if shown[id] != presentation {
                batch[window] = presentation
                shown[id] = presentation
            }
            if done { flights[id] = nil }
        }
        if !batch.isEmpty { server.submit(batch) }
        let idle = flights.isEmpty && moves.isEmpty
        var notify = false
        if !batch.isEmpty {
            committedIdle = idle
            if !notifying { notifying = true; notify = true }
        }
        lock.unlock()
        if notify {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let idle = self.lock.withLock { self.notifying = false; return self.committedIdle }
                onCommit(idle)
            }
        }
        return idle
    }
}
