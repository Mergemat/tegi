import CoreGraphics

/// A window's way from one frame to another, on springs.
public struct Flight {
    public var x, y, w, h: Spring
    public var monitor: Int

    public init(from: CGRect, to: CGRect, monitor: Int, velocity: Double?, at t: Double,
                position: SpringParams, size: SpringParams, slowdown: Double) {
        x = Spring(from: from.minX, to: to.minX, velocity: velocity ?? 0, start: t, params: position, slowdown: slowdown)
        y = Spring(from: from.minY, to: to.minY, start: t, params: position, slowdown: slowdown)
        w = Spring(from: from.width, to: to.width, start: t, params: size, slowdown: slowdown)
        h = Spring(from: from.height, to: to.height, start: t, params: size, slowdown: slowdown)
        self.monitor = monitor
    }

    public var target: CGRect { CGRect(x: x.to, y: y.to, width: w.to, height: h.to) }

    public func frame(at t: Double) -> CGRect {
        return CGRect(x: x.value(at: t), y: y.value(at: t), width: w.value(at: t), height: h.value(at: t))
    }

    public func isDone(at t: Double) -> Bool {
        return x.isDone(at: t) && y.isDone(at: t) && w.isDone(at: t) && h.isDone(at: t)
    }

    public mutating func retarget(to new: CGRect, at t: Double) {
        x = x.retargeted(to: new.minX, at: t)
        y = y.retargeted(to: new.minY, at: t)
        w = w.retargeted(to: new.width, at: t)
        h = h.retargeted(to: new.height, at: t)
    }
}
