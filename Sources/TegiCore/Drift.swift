import CoreGraphics

/// A tiled window an app moved or resized on its own, like one restoring its saved frame right after it opens.
public struct Drift {
    private var pushes: [Double] = []

    public init() {}

    /// Whether the window is no longer where tegi put it, beyond a size the app is known to keep.
    public static func strayed(_ actual: CGRect, from laidOut: CGRect, refusal: Refusal?) -> Bool {
        func off(_ expected: CGRect) -> Bool {
            abs(actual.minX - expected.minX) > 1 || abs(actual.minY - expected.minY) > 1
                || abs(actual.width - expected.width) > 1 || abs(actual.height - expected.height) > 1
        }
        return off(laidOut) && (refusal.map { off($0.apply(to: laidOut)) } ?? true)
    }

    /// Puts a window back a few times, then lets an app that insists keep its frame instead of fighting it forever.
    public mutating func allow(at time: Double) -> Bool {
        pushes = pushes.filter { time - $0 < 2 }
        guard pushes.count < 3 else { return false }
        pushes.append(time)
        return true
    }
}
