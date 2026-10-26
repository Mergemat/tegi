import Foundation

/// Trackpad contact frames to gestures, the way macOS's own work: a gesture lasts from the first finger down to the
/// last one up, its finger count is settled once the fingers have travelled a few millimetres, and movement is measured
/// finger by finger, so one landing or lifting moves nothing.
public struct TouchGestures {
    /// A finger on the trackpad, at x and y in trackpad widths and heights; y rises away from you.
    public struct Touch: Equatable {
        public var id: Int32
        public var x, y: Double

        public init(id: Int32, x: Double, y: Double) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    public enum Event: Equatable {
        case began(fingers: Int)
        case changed(dx: Double, dy: Double)
        case ended
    }

    /// Travel before a gesture is decided: about 5 mm on a laptop's trackpad, so a resting hand's tremor starts nothing.
    static let decided = 0.03

    private enum Phase {
        case idle
        case deciding(count: Int, dx: Double, dy: Double)
        case swiping(fingers: Int)
        /// Decided as something else, such as the system's two-finger scroll, until every finger is up.
        case spent
    }

    private var phase = Phase.idle
    private var last: [Int32: Touch] = [:]
    /// How many fingers (three or more) came down before the gesture was decided, so it's tegi's until every finger is
    /// up: the scrolls macOS makes of it aren't meant for the window under the pointer. 0 for none.
    public private(set) var claimed = 0

    /// The fingers of a gesture once decided, as they travel: 3 or 4, or 0 before then and after.
    public var decided: Int {
        if case .swiping(let fingers) = phase { return fingers }
        return 0
    }

    public init() {}

    public mutating func frame(_ touches: [Touch]) -> [Event] {
        defer {
            if touches.isEmpty { claimed = 0 }
            else if case .deciding(let count, _, _) = phase, count >= 3 { claimed = max(claimed, count) }
        }
        let moves = touches.compactMap { t in last[t.id].map { (dx: t.x - $0.x, dy: t.y - $0.y) } }
        let dx = moves.isEmpty ? 0 : moves.reduce(0) { $0 + $1.dx } / Double(moves.count)
        let dy = moves.isEmpty ? 0 : moves.reduce(0) { $0 + $1.dy } / Double(moves.count)
        last = Dictionary(touches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        if touches.isEmpty {
            defer { phase = .idle }
            if case .swiping = phase { return [.ended] }
            return []
        }
        switch phase {
        case .idle:
            phase = .deciding(count: touches.count, dx: 0, dy: 0)
            return []
        case .deciding(let count, var tx, var ty):
            // Fingers land one by one; the gesture is the one made with however many are down as they travel.
            guard touches.count == count else {
                phase = .deciding(count: touches.count, dx: 0, dy: 0)
                return []
            }
            tx += dx
            ty += dy
            guard hypot(tx, ty) >= Self.decided else {
                phase = .deciding(count: count, dx: tx, dy: ty)
                return []
            }
            guard count == 3 || count == 4 else {
                phase = .spent
                return []
            }
            phase = .swiping(fingers: count)
            return [.began(fingers: count)]
        case .swiping(let fingers):
            // The first finger to lift ends it, before the rest wander as they leave.
            guard touches.count == fingers else {
                phase = .spent
                return [.ended]
            }
            return [.changed(dx: dx, dy: dy)]
        case .spent:
            return []
        }
    }
}
