import Foundation

public struct SpringParams: Equatable {
    public var dampingRatio = 1.0
    public var stiffness = 800.0
    public var epsilon = 0.0001

    public init(dampingRatio: Double = 1, stiffness: Double = 800, epsilon: Double = 0.0001) {
        self.dampingRatio = dampingRatio
        self.stiffness = stiffness
        self.epsilon = epsilon
    }

    public static let view = SpringParams()
    public static let workspace = SpringParams(stiffness: 1000)
    /// Windows following fingers on the trackpad: about 15 ms behind, close enough to feel held, smoothing the steps
    /// between touch frames.
    public static let tracking = SpringParams(stiffness: 4500)

    var beta: Double { dampingRatio * stiffness.squareRoot() }
}

public struct Spring: Equatable {
    public var from: Double
    public var to: Double
    public var velocity: Double
    public var start: Double
    public var params: SpringParams
    public var slowdown: Double
    public let duration: Double

    public static let duration = Spring(from: 0, to: 1, start: 0).duration

    public init(from: Double, to: Double, velocity: Double = 0, start: Double,
                params: SpringParams = .view, slowdown: Double = 1) {
        self.from = from
        self.to = to
        self.velocity = velocity
        self.start = start
        self.params = params
        self.slowdown = max(slowdown, 0.001)
        duration = Self.settle(from: from, to: to, velocity: velocity * self.slowdown, params) * self.slowdown
    }

    static func settle(from: Double, to: Double, velocity: Double, _ p: SpringParams) -> Double {
        if from == to && velocity == 0 { return 0 }
        let beta = p.beta, omega0 = p.stiffness.squareRoot()
        guard beta > 0 else { return .infinity }
        if beta <= omega0 + Double(Float.ulpOfOne) { return -log(p.epsilon) / beta }
        let distance = max(abs(to - from), 1)
        for ms in 1...10_000 {
            let t = Double(ms) / 1000
            if abs(oscillate(t, from: from, to: to, v0: velocity, p) - to) <= p.epsilon * distance { return t }
        }
        return 10
    }

    static func oscillate(_ t: Double, from: Double, to: Double, v0: Double, _ p: SpringParams) -> Double {
        let beta = p.beta, omega0 = p.stiffness.squareRoot(), x0 = from - to
        let envelope = exp(-beta * t)
        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            return to + envelope * (x0 + (beta * x0 + v0) * t)
        } else if beta < omega0 {
            let w = (omega0 * omega0 - beta * beta).squareRoot()
            return to + envelope * (x0 * cos(w * t) + ((beta * x0 + v0) / w) * sin(w * t))
        } else {
            let w = (beta * beta - omega0 * omega0).squareRoot()
            return to + envelope * (x0 * cosh(w * t) + ((beta * x0 + v0) / w) * sinh(w * t))
        }
    }

    public func isDone(at t: Double) -> Bool { t - start >= duration }

    public func value(at t: Double) -> Double {
        if isDone(at: t) { return to }
        return Self.oscillate(max(0, t - start) / slowdown, from: from, to: to, v0: velocity * slowdown, params)
    }

    public func velocity(at t: Double) -> Double {
        if isDone(at: t) { return 0 }
        let p = params, s = max(0, t - start) / slowdown, v0 = velocity * slowdown
        let beta = p.beta, omega0 = p.stiffness.squareRoot(), x0 = from - to
        let envelope = exp(-beta * s)
        let perScaledSecond: Double
        if abs(beta - omega0) <= Double(Float.ulpOfOne) {
            perScaledSecond = envelope * (v0 - beta * (beta * x0 + v0) * s)
        } else if beta < omega0 {
            let w = (omega0 * omega0 - beta * beta).squareRoot(), c = (beta * x0 + v0) / w
            perScaledSecond = envelope * (-beta * (x0 * cos(w * s) + c * sin(w * s)) + w * (c * cos(w * s) - x0 * sin(w * s)))
        } else {
            let w = (beta * beta - omega0 * omega0).squareRoot(), c = (beta * x0 + v0) / w
            perScaledSecond = envelope * (-beta * (x0 * cosh(w * s) + c * sinh(w * s)) + w * (c * cosh(w * s) + x0 * sinh(w * s)))
        }
        return perScaledSecond / slowdown
    }

    public func retargeted(to new: Double, at t: Double, params: SpringParams? = nil) -> Spring {
        Spring(from: value(at: t), to: new, velocity: velocity(at: t), start: t, params: params ?? self.params, slowdown: slowdown)
    }
}

public struct RubberBand {
    public var stiffness: Double
    public var limit: Double

    public static let workspaces = RubberBand(stiffness: 0.5, limit: 0.05)

    public func band(_ x: Double) -> Double { (1 - 1 / (x * stiffness / limit + 1)) * limit }

    public func derivative(_ x: Double) -> Double { stiffness * limit * limit / pow(stiffness * x + limit, 2) }

    public func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        let c = min(max(x, lo), hi)
        return c + (x < c ? -1 : 1) * band(abs(x - c))
    }

    public func clampDerivative(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        lo <= x && x <= hi ? 1 : derivative(abs(x - min(max(x, lo), hi)))
    }
}

public struct SwipeTracker {
    private var history: [(position: Double, time: Double)] = []
    public private(set) var position = 0.0

    public init() {}

    public mutating func push(_ delta: Double, at time: Double) {
        if let last = history.last, time < last.time { return }
        position += delta
        history.append((position, time))
        history.removeAll { $0.time + 0.15 < time }
    }

    public var velocity: Double {
        guard let first = history.first, let last = history.last, last.time > first.time else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }

    public var projectedEnd: Double { position - velocity / (1000 * log(0.997)) }
}
