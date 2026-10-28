import Foundation

/// Recognizes swipes from a group of contacts moving together, ignoring resting and oversized contacts.
public struct TouchGestures {
    /// Coordinates use trackpad widths and heights; y rises away from the user.
    public struct Touch: Equatable, Codable {
        public var id: Int32
        public var x, y: Double
        /// Contact ellipse area in consistent device units. Zero means unavailable.
        public var area: Double
        /// MultitouchSupport's native contact state, retained for capture and replay.
        public var state: Int32

        public init(id: Int32, x: Double, y: Double, area: Double = 0, state: Int32 = 4) {
            self.id = id
            self.x = x
            self.y = y
            self.area = area
            self.state = state
        }

        public var isTouching: Bool { state == 3 || state == 4 }
    }

    public struct Frame: Codable {
        public var time: Double
        public var number: Int32
        public var touches: [Touch]
        public var valid: Bool

        public init(time: Double, number: Int32, touches: [Touch], valid: Bool = true) {
            self.time = time
            self.number = number
            self.touches = touches
            self.valid = valid
        }

        public var isValid: Bool {
            valid && time.isFinite && time >= 0 && touches.count <= 20
                && Set(touches.map(\.id)).count == touches.count
                && touches.allSatisfy {
                    (0...7).contains($0.state) && (!$0.isTouching ||
                        ($0.x.isFinite && $0.y.isFinite && $0.area.isFinite
                         && (-0.2...1.2).contains($0.x) && (-0.2...1.2).contains($0.y)))
                }
        }
    }

    public enum Event: Equatable {
        case began(fingers: Int)
        case changed(dx: Double, dy: Double)
        case ended
        case cancelled
    }

    /// How the event tap should route native scroll events for the current contact session.
    public enum ScrollRouting {
        case system
        /// Motion is a candidate; no gesture owns the native scroll yet.
        case pending
        case suppress
        case strip
    }

    private struct Contact {
        var origin: Touch
        var touch: Touch
        var palm = false
        var reserved = false
    }

    private struct Motion {
        var id: Int32
        var dx, dy: Double
        var distance: Double { hypot(dx, dy) }
    }

    private enum Phase {
        case tracking
        case system(Set<Int32>)
        case swiping(Set<Int32>)
        case finished(Set<Int32>)
    }

    private var phase = Phase.tracking
    private var contacts: [Int32: Contact] = [:]
    private var lastTime: Double?
    private var rebase = false

    public var scrollRouting: ScrollRouting {
        switch phase {
        case .tracking: movingFingers.count >= 3 ? .pending : .system
        case .system: .system
        case .swiping(let ids): ids.count == 3 ? .strip : .suppress
        case .finished: .suppress
        }
    }

    public init() {}

    public mutating func frame(_ frame: Frame) -> [Event] {
        guard frame.isValid else {
            rebase = true
            return []
        }
        guard lastTime.map({ frame.time > $0 }) ?? true else { return [] }
        lastTime = frame.time
        let touches = frame.touches.filter(\.isTouching)
        let previous = contacts
        contacts = Dictionary(touches.map { touch in
            var contact = previous[touch.id] ?? Contact(origin: touch, touch: touch)
            contact.touch = touch
            return (touch.id, contact)
        }, uniquingKeysWith: { _, new in new })
        if contacts.isEmpty {
            defer { phase = .tracking; rebase = false }
            if case .swiping = phase { return [.ended] }
            return []
        }
        if rebase {
            rebase = false
            if case .tracking = phase { resumeTracking() }
            else if case .swiping(let ids) = phase, ids.allSatisfy({ contacts[$0] != nil }) { return [] }
        }
        switch phase {
        case .system(let ids), .finished(let ids):
            // A resting palm must not keep the next gesture locked to the previous one.
            if ids.isDisjoint(with: contacts.keys) {
                resumeTracking()
            }
            return []
        case .swiping(let ids):
            // Membership is fixed: a brush adds no motion, and a replacement cannot stand in for a lifted finger.
            guard ids.allSatisfy({ contacts[$0] != nil }) else {
                phase = .finished(ids)
                if ids.isDisjoint(with: contacts.keys) { resumeTracking() }
                return [.ended]
            }
            let dx = ids.reduce(0.0) { $0 + (contacts[$1]!.touch.x - previous[$1]!.touch.x) } / Double(ids.count)
            let dy = ids.reduce(0.0) { $0 + (contacts[$1]!.touch.y - previous[$1]!.touch.y) } / Double(ids.count)
            return [.changed(dx: dx, dy: dy)]
        case .tracking:
            rejectPalms()
            let moving = movingFingers
            guard !moving.isEmpty else { return [] }
            let dx = moving.reduce(0.0) { $0 + $1.dx } / Double(moving.count)
            let dy = moving.reduce(0.0) { $0 + $1.dy } / Double(moving.count)
            // This is normalized travel, not a calibrated physical distance.
            guard hypot(dx, dy) >= 0.03 else { return [] }
            let ids = Set(moving.map(\.id))
            guard ids.count == 3 || ids.count == 4 else {
                phase = .system(ids)
                return []
            }
            phase = .swiping(ids)
            return [.began(fingers: ids.count)]
        }
    }

    public mutating func cancel() -> [Event] {
        defer { self = TouchGestures() }
        if case .swiping = phase { return [.cancelled] }
        return []
    }

    /// Contacts already used by a native scroll cannot start another gesture before lifting.
    public mutating func reserveForNativeScroll() -> [Event] {
        for id in contacts.keys { contacts[id]?.reserved = true }
        if case .swiping(let ids) = phase {
            phase = .system(ids)
            return [.cancelled]
        }
        return []
    }

    private mutating func resumeTracking() {
        phase = .tracking
        contacts = contacts.mapValues { Contact(origin: $0.touch, touch: $0.touch, palm: $0.palm, reserved: $0.reserved) }
    }

    private mutating func rejectPalms() {
        let areas = contacts.values.map(\.touch.area).filter { $0.isFinite && $0 > 0 }.sorted()
        guard areas.count >= 2 else { return }
        // The private ellipse units are unverified, so size evidence is relative to other contacts in the frame.
        let typical = areas[(areas.count - 1) / 2]
        for id in contacts.keys where contacts[id]!.touch.area.isFinite && contacts[id]!.touch.area > typical * 2.5 {
            contacts[id]?.palm = true
        }
    }

    private var movingFingers: [Motion] {
        let motions = contacts.values.filter { !$0.palm && !$0.reserved }.map {
            Motion(id: $0.touch.id, dx: $0.touch.x - $0.origin.x, dy: $0.touch.y - $0.origin.y)
        }
        guard !motions.isEmpty else { return [] }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = sorted.count / 2
            return (sorted[middle] + sorted[(sorted.count - 1) / 2]) / 2
        }
        let dx = median(motions.map(\.dx)), dy = median(motions.map(\.dy))
        let distance = hypot(dx, dy)
        guard distance >= 0.008 else { return [] }
        return motions.filter {
            $0.distance >= max(0.008, distance * 0.5) && $0.distance <= distance * 2.5
                && ($0.dx * dx + $0.dy * dy) >= 0.8 * $0.distance * distance
        }
    }
}
