import AppKit
import QuartzCore
import TegiCore

final class Motion: NSObject {
    struct Springs {
        var position: SpringParams
        var size: SpringParams
        var slowdown: Double
    }

    private var flights: [WindowID: Flight] = [:]
    private var resting: [WindowID: (frame: CGRect, monitor: Int)] = [:]
    private var link: CADisplayLink?
    private var onFrame: (CFTimeInterval) -> Void = { _ in }
    private var stats: (ticks: Int, start: Double, windows: [WindowID: (app: String, sent: Int, landed: Int)])?

    var isMoving: Bool { !flights.isEmpty }
    /// The latest time a frame was shown for; the display link runs ahead of the clock, and a press between
    /// two frames mustn't send windows back to where they were a frame ago.
    private(set) var clock: CFTimeInterval = 0

    func isFlying(_ id: WindowID) -> Bool { flights[id] != nil }

    func current(_ id: WindowID, at t: Double) -> (frame: CGRect, monitor: Int)? {
        if let f = flights[id] { return (f.frame(at: t), f.monitor) }
        return resting[id]
    }

    /// A new flight waits `delay` before it sets off, so windows from faster apps wait for slower ones.
    func move(_ id: WindowID, from: CGRect, to: CGRect, monitor: Int, at t: Double, velocity: Double? = nil,
              delay: Double = 0, springs: Springs) -> Bool {
        if var f = flights[id] {
            if f.target != to { f.retarget(to: to, at: t) }
            if let velocity { f.x.velocity = velocity }
            flights[id] = f
            return true
        }
        guard from != to else { return false }
        flights[id] = Flight(from: from, to: to, monitor: monitor, velocity: velocity, at: t, delay: delay,
                             position: springs.position, size: springs.size, slowdown: springs.slowdown)
        resting[id] = nil
        if stats == nil { stats = (0, t, [:]) }
        return true
    }

    func stop(_ id: WindowID, at rest: (CGRect, Int)?) {
        flights[id] = nil
        resting[id] = rest
    }

    func forget(where gone: (WindowID) -> Bool) {
        for id in flights.keys where gone(id) { flights[id] = nil }
        for id in resting.keys where gone(id) { resting[id] = nil }
    }

    func cancel() {
        for (id, f) in flights { resting[id] = (f.target, f.monitor) }
        flights = [:]
        stopLink()
    }

    func frames(at t: Double) -> [(id: WindowID, frame: CGRect, monitor: Int, last: Bool)] {
        var out: [(WindowID, CGRect, Int, Bool)] = []
        stats?.ticks += 1
        clock = max(clock, t)
        for (id, f) in flights {
            let done = f.isDone(at: t)
            let frame = (done ? f.target : f.frame(at: t)).roundedToPoints
            out.append((id, frame, f.monitor, done))
            if done {
                flights[id] = nil
                resting[id] = (frame, f.monitor)
            }
        }
        if flights.isEmpty { stopLink() }
        return out
    }

    func run(_ onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        guard link == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) { onFrame(link.targetTimestamp) }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    func sent(_ id: WindowID, app: String) {
        guard stats != nil else { return }
        stats?.windows[id, default: (app, 0, 0)].sent += 1
    }

    func landed(_ id: WindowID) {
        guard stats?.windows[id] != nil else { return }
        stats?.windows[id]?.landed += 1
    }

    func summary() -> String? {
        guard let s = stats else { return nil }
        stats = nil
        let elapsed = CACurrentMediaTime() - s.start
        let kept = s.windows.values.filter { $0.sent >= 5 }.map { (app: $0.app, share: Double($0.landed) / Double($0.sent)) }
        guard elapsed > 0, let slowest = kept.min(by: { $0.share < $1.share }) else { return nil }
        return String(format: "Motion at %.0f Hz; %@ kept up with %.0f%% of frames",
                      Double(s.ticks) / elapsed, slowest.app, min(1, slowest.share) * 100)
    }
}

extension CGRect {
    var roundedToPoints: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}
