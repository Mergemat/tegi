import AppKit
import TegiCore

private enum Phase {
    static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4, cancelled: Int64 = 8
    static let momentumEnded: Int64 = 3
}

final class InputTap {
    enum Event {
        case began
        case changed(dx: Double, dy: Double, time: Double)
        case ended(time: Double)
        /// macOS's own coast after the fingers lift, as any scrolled view rides it.
        case momentum(dx: Double, dy: Double, time: Double)
        case momentumEnded
        case wheel(dx: Double, dy: Double)
        case grab(right: Bool, point: CGPoint)
        case drag(point: CGPoint)
        case release(point: CGPoint)
    }

    private let modifier: CGEventFlags
    /// How many fingers are on the trackpad making tegi's gesture, three or more or 0 for none, and what it was decided
    /// as once they've moved.
    private let claimed: () -> (fingers: Int, decided: Int)
    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private var scrolling = ScrollInput()
    private var grabbing = false

    init?(modifier: Mods, claimed: @escaping () -> (fingers: Int, decided: Int), handler: @escaping (Event) -> Void) {
        var flags: CGEventFlags = []
        if modifier.contains(.alt) { flags.insert(.maskAlternate) }
        if modifier.contains(.ctrl) { flags.insert(.maskControl) }
        if modifier.contains(.cmd) { flags.insert(.maskCommand) }
        if modifier.contains(.shift) { flags.insert(.maskShift) }
        self.modifier = flags
        self.claimed = claimed
        self.handler = handler
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, me in
                                              Unmanaged<InputTap>.fromOpaque(me!).takeUnretainedValue().handle(type, event)
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        let started = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            started.signal()
            CFRunLoopRun()
        }
        started.wait()
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let loop, let source {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    private func send(_ e: Event) {
        DispatchQueue.main.async { self.handler(e) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let held = !modifier.isEmpty && event.flags.intersection([.maskAlternate, .maskControl, .maskCommand, .maskShift]) == modifier
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard held else { return Unmanaged.passUnretained(event) }
            grabbing = true
            send(.grab(right: type == .rightMouseDown, point: event.location))
            return nil
        case .leftMouseDragged, .rightMouseDragged:
            guard grabbing else { return Unmanaged.passUnretained(event) }
            send(.drag(point: event.location))
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard grabbing else { return Unmanaged.passUnretained(event) }
            grabbing = false
            send(.release(point: event.location))
            return nil
        default:
            return scrolling.handle(event, held: held, claim: claimed(), send: send)
        }
    }

}

struct ScrollInput {
    private var scrolling = false
    private var coasting = false
    private var swallowing = false

    mutating func handle(_ event: CGEvent, held: Bool, claim: (fingers: Int, decided: Int),
                         send: (InputTap.Event) -> Void) -> Unmanaged<CGEvent>? {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let time = Double(event.timestamp) / 1e9
        if phase == Phase.began, momentum == 0, coasting {
            coasting = false
            send(.momentumEnded)
        }
        // macOS makes scrolls of three and four fingers too, which aren't for the window under the pointer or the
        // overview. Three fingers scroll the strip with them, so it moves as anything scrolled on a Mac does; four are
        // the overview's, and their scroll, coast and all, goes nowhere.
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            // Fingers land one by one, so the scroll may have begun with two, going to the window under the pointer;
            // a fourth may be on its way, so three only take the strip once they've moved as three.
            if claim.decided == 3, !scrolling, momentum == 0 {
                swallowing = false
                scrolling = true
                coasting = false
                send(.began)
                if phase == Phase.began { return nil }
            } else if claim.fingers >= 3, !scrolling, !coasting {
                swallowing = true
                return nil
            }
            if swallowing {
                guard phase == Phase.began, momentum == 0 else { return nil }
                swallowing = false
            }
        }
        if phase == Phase.began { coasting = false }
        if momentum != 0 {
            guard coasting else { return Unmanaged.passUnretained(event) }
            if momentum == Phase.momentumEnded {
                coasting = false
                send(.momentumEnded)
            } else {
                send(.momentum(dx: dx, dy: dy, time: time))
            }
            return nil
        }
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
            guard held else { return Unmanaged.passUnretained(event) }
            send(.wheel(dx: dx, dy: dy))
            return nil
        }
        switch phase {
        case Phase.began where held:
            scrolling = true
            send(.began)
            return nil
        case Phase.changed where scrolling:
            send(.changed(dx: dx, dy: dy, time: time))
            return nil
        case Phase.ended, Phase.cancelled:
            guard scrolling else { break }
            scrolling = false
            coasting = phase != Phase.cancelled
            send(.ended(time: time))
            if !coasting { send(.momentumEnded) }
            return nil
        default:
            if scrolling { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
