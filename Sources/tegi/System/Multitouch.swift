import AppKit

// MultitouchSupport is private: frames are validated and the reader shuts off on bad data.
final class Multitouch {
    enum Event {
        case began
        case changed(dx: Double, dy: Double, time: Double)
        case ended(time: Double)
        case fourFingerSwipe(up: Bool)
    }

    private typealias Callback = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Start = @convention(c) (OpaquePointer, Int32) -> Int32
    private typealias Stop = @convention(c) (OpaquePointer) -> Int32
    private typealias Register = @convention(c) (OpaquePointer, Callback, UnsafeMutableRawPointer?) -> Int32
    private typealias Unregister = @convention(c) (OpaquePointer, Callback) -> Int32

    // Touch records are 96 bytes: state at 20 (4 = touching), x and y in 0...1 at 32 and 36.
    private static let stride = 96, stateOffset = 20, xOffset = 32, yOffset = 36, touching: Int32 = 4

    private let handler: (Event) -> Void
    private let natural: Bool
    private var list: CFArray?
    private var devices: [OpaquePointer] = []
    private let stop: Stop
    private let unregister: Unregister
    private let lock = NSLock()
    private var last: CGPoint?
    private var count = 0
    private var four: (start: CGPoint, fired: Bool)?
    private var bad = 0
    private(set) var dead = false

    private static let callback: Callback = { _, touches, n, time, _, me in
        guard let me else { return 0 }
        Unmanaged<Multitouch>.fromOpaque(me).takeUnretainedValue().frame(touches, Int(n), time)
        return 0
    }

    init?(handler: @escaping (Event) -> Void) {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
              let createList = dlsym(lib, "MTDeviceCreateList").map({ unsafeBitCast($0, to: CreateList.self) }),
              let start = dlsym(lib, "MTDeviceStart").map({ unsafeBitCast($0, to: Start.self) }),
              let stop = dlsym(lib, "MTDeviceStop").map({ unsafeBitCast($0, to: Stop.self) }),
              let register = dlsym(lib, "MTRegisterContactFrameCallbackWithRefcon").map({ unsafeBitCast($0, to: Register.self) }),
              let unregister = dlsym(lib, "MTUnregisterContactFrameCallback").map({ unsafeBitCast($0, to: Unregister.self) }),
              let list = createList()?.takeRetainedValue()
        else { return nil }
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
        lock.withLock { dead = true }
        for device in devices {
            _ = unregister(device, Multitouch.callback)
            _ = stop(device)
        }
        devices = []
    }

    private func frame(_ touches: UnsafeMutableRawPointer?, _ n: Int, _ time: Double) {
        var sum = CGPoint.zero, touching = 0
        if let touches, n > 0, n <= 20 {
            for i in 0..<n {
                let base = i * Self.stride
                guard touches.load(fromByteOffset: base + Self.stateOffset, as: Int32.self) == Self.touching else { continue }
                let x = Double(touches.load(fromByteOffset: base + Self.xOffset, as: Float.self))
                let y = Double(touches.load(fromByteOffset: base + Self.yOffset, as: Float.self))
                guard x.isFinite, y.isFinite, (-0.2...1.2).contains(x), (-0.2...1.2).contains(y) else {
                    lock.withLock { bad += 1 }
                    continue
                }
                sum.x += x
                sum.y += y
                touching += 1
            }
        }
        lock.lock()
        defer { lock.unlock() }
        if dead { return }
        if bad > 30 {
            dead = true
            return
        }
        let center = touching > 0 ? CGPoint(x: sum.x / Double(touching), y: sum.y / Double(touching)) : nil
        let sign = natural ? 1.0 : -1.0
        if touching == 3, let center {
            if count == 3, let last {
                let dx = (center.x - last.x) * sign, dy = -(center.y - last.y) * sign
                DispatchQueue.main.async { self.handler(.changed(dx: dx, dy: dy, time: time)) }
            } else {
                DispatchQueue.main.async { self.handler(.began) }
            }
            last = center
        } else if count == 3 {
            last = nil
            DispatchQueue.main.async { self.handler(.ended(time: time)) }
        }
        if touching == 4, let center {
            if four == nil { four = (center, false) }
            if let f = four, !f.fired, abs(center.y - f.start.y) > 0.12 {
                four?.fired = true
                let up = (center.y > f.start.y) == natural
                DispatchQueue.main.async { self.handler(.fourFingerSwipe(up: up)) }
            }
        } else if touching < 4 {
            four = nil
        }
        count = touching
    }
}
