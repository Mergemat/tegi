import AppKit
import TegiCore

// MultitouchSupport is private: frames are validated and the reader shuts off on bad data.
final class Multitouch {
    enum Event {
        case began(fingers: Int)
        case changed(dx: Double, dy: Double, time: Double)
        case ended(time: Double)
        case cancelled
    }

    private typealias Callback = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Start = @convention(c) (OpaquePointer, Int32) -> Int32
    private typealias Stop = @convention(c) (OpaquePointer) -> Int32
    private typealias Register = @convention(c) (OpaquePointer, Callback, UnsafeMutableRawPointer?) -> Int32
    private typealias Unregister = @convention(c) (OpaquePointer, Callback) -> Int32

    // MultitouchSupport's 96-byte contact layout; ellipse axes follow the angle at byte 56.
    private static let stride = 96, idOffset = 16, stateOffset = 20, xOffset = 32, yOffset = 36
    private static let majorAxisOffset = 60, minorAxisOffset = 64

    private let handler: (Event) -> Void
    private let natural: Bool
    private var list: CFArray?
    private var devices: [OpaquePointer] = []
    private let stop: Stop
    private let unregister: Unregister
    private let lock = NSLock()
    private var gestures = TrackpadGestures()
    private let trace: InputTrace
    var scrollRouting: TouchGestures.ScrollRouting { lock.withLock { dead ? .system : gestures.scrollRouting } }
    private var bad = 0
    private var stopped = false
    private(set) var dead = false

    private static let callback: Callback = { device, touches, n, time, number, me in
        guard let me else { return 0 }
        Unmanaged<Multitouch>.fromOpaque(me).takeUnretainedValue().frame(device, touches, Int(n), time, number)
        return 0
    }

    init?(trace: InputTrace, handler: @escaping (Event) -> Void) {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let createList = dlsym(lib, "MTDeviceCreateList").map({ unsafeBitCast($0, to: CreateList.self) }),
              let start = dlsym(lib, "MTDeviceStart").map({ unsafeBitCast($0, to: Start.self) }),
              let stop = dlsym(lib, "MTDeviceStop").map({ unsafeBitCast($0, to: Stop.self) }),
              let register = dlsym(lib, "MTRegisterContactFrameCallbackWithRefcon").map({ unsafeBitCast($0, to: Register.self) }),
              let unregister = dlsym(lib, "MTUnregisterContactFrameCallback").map({ unsafeBitCast($0, to: Unregister.self) }),
              let list = createList()?.takeRetainedValue()
        else { return nil }
        self.trace = trace
        self.handler = handler
        self.stop = stop
        self.unregister = unregister
        self.list = list
        natural = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.swipescrolldirection"] as? Bool ?? true
        let me = Unmanaged.passUnretained(self).toOpaque()
        for i in 0..<CFArrayGetCount(list) {
            let device = OpaquePointer(CFArrayGetValueAtIndex(list, i)!)
            _ = register(device, Multitouch.callback, me)
            _ = start(device, 0)
            devices.append(device)
        }
        guard !devices.isEmpty else { return nil }
    }

    func shutdown() {
        let events = lock.withLock {
            dead = true
            stopped = true
            return gestures.cancel()
        }
        if !events.isEmpty { handler(.cancelled) }
        for device in devices {
            _ = unregister(device, Multitouch.callback)
            _ = stop(device)
        }
        devices = []
    }

    func blockTouches(_ active: Bool) {
        let cancelled = lock.withLock {
            guard !stopped else { return false }
            let events = gestures.blockTouches(active)
            trace.record(["kind": "scroll_reservation", "blocked": active, "events": events.map { String(describing: $0) }])
            return events.contains(.cancelled)
        }
        if cancelled {
            DispatchQueue.main.async {
                if self.lock.withLock({ !self.stopped }) { self.handler(.cancelled) }
            }
        }
    }

    static func decode(_ touches: UnsafeRawPointer?, count n: Int, time: Double, number: Int32) -> TouchGestures.Frame {
        var contacts: [TouchGestures.Touch] = []
        var valid = (0...20).contains(n) && (n == 0 || touches != nil)
        if let touches, n > 0, n <= 20 {
            for i in 0..<n {
                let base = i * Self.stride
                let state = touches.load(fromByteOffset: base + Self.stateOffset, as: Int32.self)
                let x = Double(touches.load(fromByteOffset: base + Self.xOffset, as: Float.self))
                let y = Double(touches.load(fromByteOffset: base + Self.yOffset, as: Float.self))
                if (state == 3 || state == 4) && (!x.isFinite || !y.isFinite) { valid = false }
                let major = Double(touches.load(fromByteOffset: base + Self.majorAxisOffset, as: Float.self))
                let minor = Double(touches.load(fromByteOffset: base + Self.minorAxisOffset, as: Float.self))
                let area = major.isFinite && minor.isFinite && major > 0 && minor > 0 ? major * minor : 0
                contacts.append(.init(id: touches.load(fromByteOffset: base + Self.idOffset, as: Int32.self),
                                      x: x.isFinite ? x : 0, y: y.isFinite ? y : 0, area: area, state: state))
            }
        }
        return .init(time: time, number: number, touches: contacts, valid: valid)
    }

    private func frame(_ device: OpaquePointer, _ touches: UnsafeMutableRawPointer?, _ n: Int, _ time: Double, _ number: Int32) {
        let arrival = ProcessInfo.processInfo.systemUptime
        let frame = Self.decode(touches, count: n, time: time, number: number)
        let deviceID = UInt64(UInt(bitPattern: device))
        lock.lock()
        defer { lock.unlock() }
        if dead { return }
        if !frame.isValid { bad += 1 }
        var events = gestures.frame(frame, device: deviceID)
        if bad > 30 {
            dead = true
            events += gestures.cancel()
        }
        if trace.isRecording {
            let raw = touches.flatMap { n > 0 && n <= 20 ? Data(bytes: $0, count: n * Self.stride) : nil }
            trace.record([
                "kind": "touch", "device": String(deviceID), "number": number, "count": n,
                "time": time.isFinite ? time as Any : NSNull(), "valid": frame.isValid,
                "touches": frame.touches.map { ["id": $0.id, "state": $0.state, "x": $0.x, "y": $0.y, "area": $0.area] },
                "raw": raw?.base64EncodedString() ?? "", "routing": String(describing: gestures.scrollRouting),
                "events": events.map { String(describing: $0) }, "reader_dead": dead,
                "natural_scrolling": natural, "record_size": Self.stride,
            ], arrival: arrival)
        }
        let sign = natural ? 1.0 : -1.0
        for event in events {
            let out: Event = switch event {
            case .began(let fingers): .began(fingers: fingers)
            case .changed(let dx, let dy): .changed(dx: dx * sign, dy: -dy * sign, time: time)
            case .ended: .ended(time: time)
            case .cancelled: .cancelled
            }
            DispatchQueue.main.async {
                let deliver = self.lock.withLock { !self.stopped && (!self.dead || event == .cancelled) }
                if deliver { self.handler(out) }
            }
        }
    }
}

/// Independent device histories, with one gesture controlling the window manager at a time.
struct TrackpadGestures {
    private var devices: [UInt64: TouchGestures] = [:]
    private var times: [UInt64: Double] = [:]
    private var touching: Set<UInt64> = []
    private var active: UInt64?
    private var blocked = false
    private var touchesBlockedByScroll = false

    var scrollRouting: TouchGestures.ScrollRouting {
        guard !blocked, !touchesBlockedByScroll, touching.count == 1, let device = touching.first else { return .system }
        return devices[device]?.scrollRouting ?? .system
    }

    mutating func frame(_ frame: TouchGestures.Frame, device: UInt64) -> [TouchGestures.Event] {
        guard frame.isValid else {
            _ = devices[device, default: TouchGestures()].frame(frame)
            return []
        }
        guard times[device].map({ frame.time > $0 }) ?? true else { return [] }
        times[device] = frame.time
        if frame.touches.contains(where: \.isTouching) { touching.insert(device) }
        else { touching.remove(device) }
        if blocked {
            if touching.isEmpty { blocked = false }
            return []
        }
        // Native scroll events lack this device key, so simultaneous digitizers cannot safely share a claim.
        if touching.count > 1 {
            blocked = true
            let events: [TouchGestures.Event] = active == nil ? [] : [.cancelled]
            active = nil
            devices = [:]
            return events
        }
        let events = devices[device, default: TouchGestures()].frame(frame)
        if touchesBlockedByScroll {
            _ = devices[device]?.reserveForNativeScroll()
            return []
        }
        if active == device {
            if events.contains(.ended) || events.contains(.cancelled) { active = nil }
            return events
        }
        if active == nil, events.contains(where: { if case .began = $0 { true } else { false } }) {
            active = device
            return events
        }
        return []
    }

    mutating func blockTouches(_ active: Bool) -> [TouchGestures.Event] {
        touchesBlockedByScroll = active
        if active {
            for device in devices.keys { _ = devices[device]?.reserveForNativeScroll() }
        }
        guard active, self.active != nil else { return [] }
        self.active = nil
        return [.cancelled]
    }

    mutating func cancel() -> [TouchGestures.Event] {
        defer { self = TrackpadGestures() }
        return active == nil ? [] : [.cancelled]
    }
}
