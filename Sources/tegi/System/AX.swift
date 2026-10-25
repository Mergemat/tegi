import AppKit
import ApplicationServices
import TegiCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    var windowID: CGWindowID
    var tileable: Bool
    var floatable: Bool
    var minimized: Bool
    var fullscreen: Bool
    var frame: CGRect?
    var title: String
}

extension AXUIElement {
    func value(_ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, attr as CFString, &v) == .success ? v : nil
    }

    func bool(_ attr: String) -> Bool { (value(attr) as? Bool) ?? false }

    func set(_ attr: String, _ v: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attr as CFString, v)
    }

    var windows: [AXUIElement] { (value(kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    func info() -> WindowInfo? {
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXFullScreenButtonAttribute,
                     kAXMinimizedAttribute, "AXFullScreen", kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute] as CFArray
        var out: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(self, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
              let values = out as? [CFTypeRef], values.count == 8 else { return nil }
        func ok(_ v: CFTypeRef) -> CFTypeRef? {
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
        guard ok(values[0]) as? String == kAXWindowRole else { return nil }
        var frame: CGRect?
        if let p = ok(values[5]), let s = ok(values[6]) {
            var origin = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &origin)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            frame = CGRect(origin: origin, size: size)
        }
        var windowID: CGWindowID = 0
        _ = _AXUIElementGetWindow(self, &windowID)
        return WindowInfo(
            windowID: windowID,
            tileable: ok(values[1]) as? String == kAXStandardWindowSubrole && ok(values[2]) != nil,
            floatable: [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole]
                .contains(ok(values[1]) as? String ?? "") && (frame.map { $0.width >= 100 && $0.height >= 60 } ?? false),
            minimized: ok(values[3]) as? Bool ?? false,
            fullscreen: ok(values[4]) as? Bool ?? false,
            frame: frame,
            title: ok(values[7]) as? String ?? "")
    }

    func setFrame(_ frame: CGRect, resize: Bool, verify: Bool) -> CGSize? {
        var origin = frame.origin, size = frame.size
        let p = AXValueCreate(.cgPoint, &origin)!, s = AXValueCreate(.cgSize, &size)!
        guard resize else {
            set(kAXPositionAttribute, p)
            return nil
        }
        guard verify else {
            set(kAXSizeAttribute, s)
            set(kAXPositionAttribute, p)
            return nil
        }
        // macOS clamps a resize at the screen edge nearest the window's current spot.
        set(kAXSizeAttribute, s)
        set(kAXPositionAttribute, p)
        set(kAXSizeAttribute, s)
        var actual = CGSize.zero
        guard let v = value(kAXSizeAttribute) else { return nil }
        AXValueGetValue(v as! AXValue, .cgSize, &actual)
        return actual
    }
}

final class AppWorker {
    enum Event { case created, destroyed, focused, moved, resized, minimized, restored, retitled }

    let pid: pid_t
    let app: AXUIElement
    let bundleID: String?
    let name: String
    let icon: NSImage?
    private let queue: DispatchQueue
    private var observer: AXObserver?
    private let onEvent: (AppWorker, AXUIElement, Event) -> Void

    private let lock = NSLock()
    private var pending: [WindowID: Job] = [:]
    private var delay = 0.0
    /// How long this app takes from tegi's order to a window actually moved, averaged over recent moves.
    var lag: Double {
        lock.lock()
        defer { lock.unlock() }
        return delay
    }


    private struct Job {
        var window: AXUIElement
        var frame: CGRect
        var resize: Bool
        var verify: Bool
        var measured: (WindowID, CGSize) -> Void
        var sent = CACurrentMediaTime()
        var done: () -> Void
    }
    private var draining = false
    private var enhancedOff = false
    private var enhancedChecked = -Double.infinity
    private var drains = 0

    init(_ app: NSRunningApplication, onEvent: @escaping (AppWorker, AXUIElement, Event) -> Void) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        name = app.localizedName ?? bundleID ?? "pid \(pid)"
        icon = app.icon
        self.app = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "tegi.app.\(pid)", qos: .userInteractive)
        self.onEvent = onEvent
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    func start(attempt: Int = 0, windows: @escaping ([(AXUIElement, WindowInfo)]) -> Void) {
        queue.async { [self] in
            if observer == nil {
                var obs: AXObserver?
                let callback: AXObserverCallback = { _, element, name, refcon in
                    let worker = Unmanaged<AppWorker>.fromOpaque(refcon!).takeUnretainedValue()
                    let event: Event? = switch name as String {
                    case kAXWindowCreatedNotification: .created
                    case kAXUIElementDestroyedNotification: .destroyed
                    case kAXFocusedWindowChangedNotification: .focused
                    case kAXWindowMovedNotification: .moved
                    case kAXWindowResizedNotification: .resized
                    case kAXWindowMiniaturizedNotification: .minimized
                    case kAXWindowDeminiaturizedNotification: .restored
                    case kAXTitleChangedNotification: .retitled
                    default: nil
                    }
                    if let event { worker.onEvent(worker, element, event) }
                }
                if AXObserverCreate(pid, callback, &obs) == .success, let obs {
                    observer = obs
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
                }
            }
            let ok = observer != nil && [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification].allSatisfy {
                let r = AXObserverAddNotification(observer!, app, $0 as CFString, refcon)
                return r == .success || r == .notificationAlreadyRegistered
            }
            guard ok else {
                if attempt < 20 {
                    queue.asyncAfter(deadline: .now() + 0.25) { self.start(attempt: attempt + 1, windows: windows) }
                }
                return
            }
            let found = app.windows.compactMap { el in el.info().map { (el, $0) } }
            DispatchQueue.main.async { windows(found) }
        }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func watch(_ window: AXUIElement) {
        queue.async { [self] in
            guard let observer else { return }
            for n in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, window, n as CFString, refcon)
            }
        }
    }

    func read(_ window: AXUIElement, then: @escaping (WindowInfo?) -> Void) {
        queue.async {
            let info = window.info()
            DispatchQueue.main.async { then(info) }
        }
    }

    func focusedWindow(then: @escaping (AXUIElement?) -> Void) {
        queue.async { [self] in
            let w = app.value(kAXFocusedWindowAttribute)
            DispatchQueue.main.async { then(w.map { $0 as! AXUIElement }) }
        }
    }

    func apply(_ id: WindowID, _ window: AXUIElement, _ frame: CGRect, resize: Bool, verify: Bool = true,
               measured: @escaping (WindowID, CGSize) -> Void, done: @escaping () -> Void) {
        lock.lock()
        let resize = resize || pending[id]?.resize == true
        pending[id] = Job(window: window, frame: frame, resize: resize, verify: verify, measured: measured, done: done)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        lock.lock()
        let jobs = pending
        pending = [:]
        lock.unlock()
        // While this is on, some apps animate every frame change themselves. Asking costs a round trip to the app,
        // hundreds of milliseconds when it's busy, so not every frame: tools that turn it on don't do so often.
        let now = CACurrentMediaTime()
        if !enhancedOff, now - enhancedChecked > 5 {
            enhancedChecked = now
            if app.bool("AXEnhancedUserInterface") {
                app.set("AXEnhancedUserInterface", kCFBooleanFalse)
                enhancedOff = true
            }
        }
        for (id, job) in jobs {
            let actual = job.window.setFrame(job.frame, resize: job.resize, verify: job.verify)
            let took = CACurrentMediaTime() - job.sent
            lock.lock()
            delay = delay == 0 ? took : delay * 0.85 + took * 0.15
            lock.unlock()
            DispatchQueue.main.async {
                if let actual { job.measured(id, actual) }
                job.done()
            }
        }
        drains += 1
        if enhancedOff {
            let drain = drains
            queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                guard drain == drains, enhancedOff else { return }
                app.set("AXEnhancedUserInterface", kCFBooleanTrue)
                enhancedOff = false
                enhancedChecked = -.infinity
            }
        }
        lock.lock()
        let more = !pending.isEmpty
        if !more { draining = false }
        lock.unlock()
        if more { queue.async { [self] in self.drain() } }
    }

    func focus(_ window: AXUIElement, then: (() -> Void)? = nil) {
        queue.async { [self] in
            app.set(kAXFrontmostAttribute, kCFBooleanTrue)
            window.set(kAXMainAttribute, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            if let then { DispatchQueue.main.async(execute: then) }
        }
    }

    func close(_ window: AXUIElement) {
        queue.async {
            guard let button = window.value(kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    func flush(_ group: DispatchGroup) {
        group.enter()
        queue.async { group.leave() }
    }
}
