import AppKit
import QuartzCore

enum LiveWindowLayer {
    private static let type: CALayer.Type? = {
        guard let type = NSClassFromString("CAPluginLayer") as? CALayer.Type else { return nil }
        let layer = type.init()
        return ["setPluginType:", "setPluginId:", "setPluginFlags:", "setPluginGravity:"].allSatisfy {
            layer.responds(to: NSSelectorFromString($0))
        } ? type : nil
    }()

    static var available: Bool { type != nil }

    static func make(_ window: CGWindowID) -> CALayer? {
        guard let type, window != 0 else { return nil }
        let layer = type.init()
        layer.name = "live"
        layer.setValue("com.apple.WindowServer.CGSWindow", forKey: "pluginType")
        layer.setValue(NSNumber(value: window), forKey: "pluginId")
        layer.setValue(4, forKey: "pluginFlags")
        layer.setValue("resizeAspect", forKey: "pluginGravity")
        return layer
    }
}

final class WindowServer {
    struct Driver {
        var bounds: (CGWindowID) -> CGRect?
        /// Where a window really is. A move another app's window refuses still shows in the mover's own `bounds`.
        var placed: ((CGWindowID) -> CGRect?)? = nil
        var submit: ([CGWindowID: CGPoint]) -> Void
        /// Orders a window above (1) or below (-1) another, or out of the window list (0).
        var order: (CGWindowID, Int32, CGWindowID) -> Void = { _, _, _ in }

        static func load() -> Driver? {
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
            func symbol<T>(_ name: String, as: T.Type) -> T? {
                dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
            }
            typealias Connection = @convention(c) () -> Int32
            typealias Bounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
            typealias Create = @convention(c) (Int32) -> Unmanaged<CFTypeRef>
            typealias Move = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
            typealias Commit = @convention(c) (CFTypeRef, Int32) -> Void
            typealias Order = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
            guard let connection = symbol("SLSMainConnectionID", as: Connection.self),
                  let bounds = symbol("SLSGetWindowBounds", as: Bounds.self),
                  let create = symbol("SLSTransactionCreate", as: Create.self),
                  let move = symbol("SLSTransactionMoveWindowWithGroup", as: Move.self),
                  let commit = symbol("SLSTransactionCommit", as: Commit.self),
                  let order = symbol("SLSOrderWindow", as: Order.self) else { return nil }
            let cid = connection()
            return Driver(bounds: { id in
                var frame = CGRect.zero
                return bounds(cid, id, &frame) == 0 ? frame : nil
            }, placed: { id in
                // The window server wants raw window numbers, not CFNumbers.
                var ids = [UnsafeRawPointer(bitPattern: UInt(id))]
                guard let array = CFArrayCreate(nil, &ids, 1, nil),
                      let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]],
                      let bounds = list.first?[kCGWindowBounds as String] as! CFDictionary? else { return nil }
                return CGRect(dictionaryRepresentation: bounds)
            }, submit: { frames in
                let transaction = create(cid).takeRetainedValue()
                for (id, point) in frames { move(transaction, id, point) }
                commit(transaction, 0)
            }, order: { id, mode, relative in _ = order(cid, id, mode, relative) })
        }
    }

    private let driver: Driver?
    // The compositor's thread submits; the main thread configures and reads how it went.
    private let lock = NSLock()
    private var enabled = false
    private var checked = false
    private var commits = 0
    private var commitMS = 0.0
    private var peakMS = 0.0
    var frames: Int { lock.withLock { commits } }
    var maxCommitMS: Double { lock.withLock { peakMS } }
    var meanCommitMS: Double { lock.withLock { commits == 0 ? 0 : commitMS / Double(commits) } }
    private var refusal: String?
    var failure: String? { lock.withLock { refusal } }
    /// Main thread: macOS refused a move, so Accessibility takes over.
    var onRefused: () -> Void = {}
    private(set) var liveScenes = false
    private(set) var authorizing = false
    private(set) var authorizationFailure: String?
    private var authorizationGranted = false
    var onChange: () -> Void = {}
    /// Turned on, and nothing has gone wrong.
    var wanted: Bool { driver != nil && lock.withLock { enabled && refusal == nil } }
    /// Moving other apps' windows. The window server only lets a process do that once the Dock has granted its
    /// connection; until then a move shows in tegi's own view of a window and nowhere else.
    var active: Bool { wanted && lock.withLock { authorizationGranted } }
    /// Why it isn't fully working, for Settings to show in place of its description.
    var problem: String? {
        guard lock.withLock({ enabled }) else { return nil }
        if failure != nil { return "macOS refused it, so windows move the standard way." }
        if driver == nil { return "Not available on this macOS." }
        if let authorizationFailure { return "Windows move the standard way: \(authorizationFailure)." }
        return nil
    }

    /// How long the window list takes to show a committed move; checked sooner, every move looks refused.
    private let settle: TimeInterval
    private var latest: [CGWindowID: CGPoint] = [:]
    private var probing = false

    init(driver: Driver? = .load(), settle: TimeInterval = 0.1) {
        self.driver = driver
        self.settle = settle
    }

    func configure(enabled: Bool) {
        guard lock.withLock({ () -> Bool in
            guard enabled != self.enabled else { return false }
            self.enabled = enabled
            checked = false
            refusal = nil
            latest = [:]
            probing = false
            return true
        }) else { return }
        if !enabled { liveScenes = false }
    }

    func authorizeLiveScenes() {
        guard wanted, !liveScenes, !authorizing else { return }
        guard LiveWindowLayer.available else {
            authorizationFailure = "this macOS can't show live windows"
            onChange()
            return
        }
        if lock.withLock({ authorizationGranted }) {
            liveScenes = true
            onChange()
            return
        }
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("tegi-dock-loader").path) else {
            authorizationFailure = "the Dock helper is missing"
            onChange()
            return
        }
        authorizing = true
        authorizationFailure = nil
        onChange()
        let connection = Self.connectionID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem: String?
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tg.\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let payload = directory.appendingPathComponent("grant.dylib")
                try FileManager.default.copyItem(at: resources.appendingPathComponent("tegi-grant.dylib"), to: payload)
                let words = [resources.appendingPathComponent("tegi-dock-loader").path, payload.path, String(connection)]
                let command = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
                let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                var error: NSDictionary?
                NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges")?.executeAndReturnError(&error)
                problem = error == nil ? nil : "the password prompt was cancelled"
            } catch {
                problem = "could not prepare the Dock helper"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizing = false
                guard self.enabled else { return }
                self.liveScenes = problem == nil && self.lock.withLock { self.authorizationGranted }
                self.authorizationFailure = self.liveScenes ? nil : problem ?? "macOS refused to let tegi move windows"
                self.onChange()
            }
        }
    }

    func acceptAuthorization(connection: Int32) -> Bool {
        guard connection == Self.connectionID else { return false }
        lock.withLock { authorizationGranted = true }
        liveScenes = active
        onChange()
        return true
    }

    /// Called on the main thread with a window that the window server put somewhere else in the stacking order.
    static var onReorder: (CGWindowID) -> Void = { _ in }
    private static var watched: [CGWindowID] = []

    /// macOS only tells a process about windows it asks after, and each request replaces the last.
    static func watchOrder(of windows: [CGWindowID]) {
        let windows = windows.sorted()
        guard windows != watched, let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return }
        typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
        typealias Register = @convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32
        typealias Request = @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> Int32
        guard let register = dlsym(library, "SLSRegisterConnectionNotifyProc"),
              let request = dlsym(library, "SLSRequestNotificationsForWindows") else { return }
        if watched.isEmpty {
            // 808 is the window server's "window ordered" event; its data starts with the window's number.
            let handler: Handler = { _, data, length, _ in
                guard let data, length >= 4 else { return }
                let window = data.loadUnaligned(as: UInt32.self)
                DispatchQueue.main.async { WindowServer.onReorder(window) }
            }
            _ = unsafeBitCast(register, to: Register.self)(connectionID, handler, 808, nil)
        }
        watched = windows
        _ = windows.withUnsafeBufferPointer { unsafeBitCast(request, to: Request.self)(connectionID, $0.baseAddress, Int32($0.count)) }
    }

    static let connectionID: Int32 = {
        typealias Function = @convention(c) () -> Int32
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(library, "SLSMainConnectionID") else { return 0 }
        return unsafeBitCast(symbol, to: Function.self)()
    }()




    func raise(_ id: CGWindowID, above other: CGWindowID) {
        guard active else { return }
        driver?.order(id, 1, other)
    }
    private static func onDisplay(_ frame: CGRect) -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).contains(frame) }
    }

    // Transaction setters don't return errors. Where the window list has a window a moment later confirms the first
    // actual move, including systems where the server silently ignores another app's windows.
    func submit(_ frames: [CGWindowID: CGPoint]) {
        guard let driver, !frames.isEmpty, active else { return }
        let placed = driver.placed ?? driver.bounds
        // Only a window going somewhere wholly on a display: macOS keeps a sliver of some parked windows its own way.
        let probe = lock.withLock { checked || probing } ? nil : frames.first { id, point in
            placed(id).map { $0.origin != point && Self.onDisplay(CGRect(origin: point, size: $0.size)) } ?? false
        }
        let start = CACurrentMediaTime()
        driver.submit(frames)
        let elapsed = (CACurrentMediaTime() - start) * 1000
        lock.withLock {
            commits += 1
            commitMS += elapsed
            peakMS = max(peakMS, elapsed)
            if !checked { latest.merge(frames) { _, new in new } }
            if probe != nil { probing = true }
        }
        guard let (id, target) = probe else { return }
        let verify = { [self] in
            let actual = placed(id)
            let refused = lock.withLock { () -> Bool? in
                probing = false
                // Moved on since, or gone: nothing to tell from it; the next move is checked instead.
                guard latest[id] == target, let actual else { return nil }
                return abs(actual.minX - target.x) >= 1 || abs(actual.minY - target.y) >= 1
            }
            guard let refused else { return }
            lock.withLock {
                if refused { refusal = "macOS refused the move" } else { checked = true }
                latest = [:]
            }
            if refused { DispatchQueue.main.async { [self] in onRefused() } }
        }
        if settle == 0 { verify() } else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + settle, execute: verify) }
    }
}
