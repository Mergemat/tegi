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
        case wheel(dx: Double, dy: Double)
        case grab(right: Bool, point: CGPoint)
        case drag(point: CGPoint)
        case release(point: CGPoint)
    }

    private let modifier: CGEventFlags
    private let handler: (Event) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private var scrolling = false
    private var coasting = false
    private var grabbing = false

    init?(modifier: Mods, handler: @escaping (Event) -> Void) {
        var flags: CGEventFlags = []
        if modifier.contains(.alt) { flags.insert(.maskAlternate) }
        if modifier.contains(.ctrl) { flags.insert(.maskControl) }
        if modifier.contains(.cmd) { flags.insert(.maskCommand) }
        if modifier.contains(.shift) { flags.insert(.maskShift) }
        guard !flags.isEmpty else { return nil }
        self.modifier = flags
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
        let held = event.flags.intersection([.maskAlternate, .maskControl, .maskCommand, .maskShift]) == modifier
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
            return scroll(event, held)
        }
    }

    private func scroll(_ event: CGEvent, _ held: Bool) -> Unmanaged<CGEvent>? {
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let time = Double(event.timestamp) / 1e9
        if phase == Phase.began { coasting = false }
        if momentum != 0 {
            // macOS's own coast after a claimed swipe; tegi coasts and snaps by itself.
            if coasting {
                if momentum == Phase.momentumEnded { coasting = false }
                return nil
            }
            return Unmanaged.passUnretained(event)
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
            coasting = true
            send(.ended(time: time))
            return nil
        default:
            if scrolling { return nil }
        }
        return Unmanaged.passUnretained(event)
    }
}
