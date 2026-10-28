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
    private let scrollRouting: () -> TouchGestures.ScrollRouting
    private let trace: InputTrace
    private let blockTouches: (Bool) -> Void
    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private var scrolling = ScrollInput()
    private var grabbing = false

    init?(modifier: Mods, trace: InputTrace, scrolling: ScrollInput, scrollRouting: @escaping () -> TouchGestures.ScrollRouting,
          blockTouches: @escaping (Bool) -> Void, handler: @escaping (Event) -> Void) {
        var flags: CGEventFlags = []
        if modifier.contains(.alt) { flags.insert(.maskAlternate) }
        if modifier.contains(.ctrl) { flags.insert(.maskControl) }
        if modifier.contains(.cmd) { flags.insert(.maskCommand) }
        if modifier.contains(.shift) { flags.insert(.maskShift) }
        self.modifier = flags
        self.scrollRouting = scrollRouting
        self.trace = trace
        self.blockTouches = blockTouches
        self.scrolling = scrolling
        self.handler = handler
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { proxy, type, event, me in
                                              Unmanaged<InputTap>.fromOpaque(me!).takeUnretainedValue().handle(type, event, proxy: proxy)
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

    @discardableResult
    func stop() -> ScrollInput {
        guard let tap else { return ScrollInput() }
        CGEvent.tapEnable(tap: tap, enable: false)
        var remainder = ScrollInput()
        if let loop, let source {
            let stopped = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                remainder = self.scrolling.forRestart(replay: { $0.post(tap: .cgSessionEventTap) })
                CFRunLoopRemoveSource(loop, source, .commonModes)
                CFRunLoopStop(loop)
                stopped.signal()
            }
            CFRunLoopWakeUp(loop)
            stopped.wait()
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        return remainder
    }

    private func send(_ e: Event) {
        DispatchQueue.main.async { if self.tap != nil { self.handler(e) } }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        let arrival = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            trace.record(["kind": "tap_disabled", "type": type.rawValue], arrival: arrival)
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
            let routing = scrollRouting()
            let wereTouchesBlocked = scrolling.blocksTouches
            let recording = trace.isRecording
            var emitted: [String] = []
            let result = scrolling.handle(event, held: held, routing: routing, replay: { $0.tapPostEvent(proxy) }) {
                if recording { emitted.append(String(describing: $0)) }
                send($0)
            }
            if wereTouchesBlocked != scrolling.blocksTouches { blockTouches(scrolling.blocksTouches) }
            if recording {
                trace.record([
                    "kind": "scroll", "time_ns": event.timestamp,
                    "phase": event.getIntegerValueField(.scrollWheelEventScrollPhase),
                    "momentum": event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                    "continuous": event.getIntegerValueField(.scrollWheelEventIsContinuous),
                    "dx": event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                    "dy": event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                    "held": held, "routing": String(describing: routing),
                    "owner": scrolling.owner?.rawValue ?? "none", "suppressed": result == nil,
                    "events": emitted,
                ], arrival: arrival)
            }
            return result
        }
    }

}

struct ScrollInput {
    enum Owner: String { case pending, system, strip, suppressed }
    private struct Stream {
        var owner: Owner
        var direct = true
        var cancelled = false
    }
    private var stream: Stream?
    private var pending: [CGEvent] = []
    var owner: Owner? { stream?.owner }
    var blocksTouches: Bool {
        guard let stream else { return false }
        return stream.direct && (stream.owner == .system || stream.cancelled)
    }

    func forRestart(replay: (CGEvent) -> Void) -> ScrollInput {
        var next = self
        if next.stream?.owner == .pending {
            pending.forEach(replay)
            next.pending = []
            next.stream?.owner = .system
        }
        if var current = next.stream, current.owner != .system {
            // An interrupted tegi interaction must drain its native remainder without leaking orphan phases to an app.
            current.owner = .suppressed
            current.cancelled = true
            next.stream = current
        }
        return next
    }

    mutating func handle(_ event: CGEvent, held: Bool, routing: TouchGestures.ScrollRouting,
                         replay: (CGEvent) -> Void = { _ in }, send: (InputTap.Event) -> Void) -> Unmanaged<CGEvent>? {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let time = Double(event.timestamp) / 1e9
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else {
            guard held else { return Unmanaged.passUnretained(event) }
            send(.wheel(dx: dx, dy: dy))
            return nil
        }
        let begins = phase & Phase.began != 0
        let changes = phase & Phase.changed != 0
        let cancelled = phase & Phase.cancelled != 0
        let ends = cancelled || phase & Phase.ended != 0
        if momentum != 0 {
            guard let stream, !stream.direct else { return Unmanaged.passUnretained(event) }
            if stream.owner == .strip, !stream.cancelled {
                if momentum == Phase.momentumEnded { send(.momentumEnded) }
                else { send(.momentum(dx: dx, dy: dy, time: time)) }
            }
            if momentum == Phase.momentumEnded { self.stream = nil }
            return stream.owner == .system ? Unmanaged.passUnretained(event) : nil
        }
        if begins {
            pending.forEach(replay)
            pending = []
            if stream?.owner == .strip {
                if stream?.direct == true { send(.ended(time: time)) }
                send(.momentumEnded)
            }
            stream = nil
        }
        // Once any direct scroll is delivered to an app, its remaining phases and tail stay with that app.
        // Pending recognition cannot discard a prefix and later pretend it was passed through.
        if stream == nil, begins || changes, !ends {
            let owner: Owner = routing == .suppress ? .suppressed : held || routing == .strip ? .strip : routing == .pending ? .pending : .system
            stream = Stream(owner: owner)
            if owner == .strip { send(.began) }
        }
        guard var current = stream else { return Unmanaged.passUnretained(event) }
        if current.owner == .pending {
            let elapsed = pending.first.map { (Double(event.timestamp) - Double($0.timestamp)) / 1e9 } ?? 0
            // Keep the prefix until contact recognition chooses an owner; ambiguity has a bounded delay.
            if routing == .pending, !ends, elapsed < 0.08, let copy = event.copy() {
                pending.append(copy)
                return nil
            }
            let buffered = pending
            pending = []
            stream = nil
            let resolved: TouchGestures.ScrollRouting = routing == .pending ? .system : routing
            for prefix in buffered {
                if handle(prefix, held: held, routing: resolved, replay: replay, send: send) != nil { replay(prefix) }
            }
            return handle(event, held: held, routing: resolved, replay: replay, send: send)
        }
        if current.direct {
            if current.owner == .strip {
                if !ends, (begins || changes), dx != 0 || dy != 0 { send(.changed(dx: dx, dy: dy, time: time)) }
                if ends {
                    send(.ended(time: time))
                    if cancelled { send(.momentumEnded) }
                }
            }
            if ends {
                current.direct = false
                current.cancelled = cancelled
                stream = current
            }
        }
        return current.owner == .system ? Unmanaged.passUnretained(event) : nil
    }
}
