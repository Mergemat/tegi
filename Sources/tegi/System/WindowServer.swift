import AppKit
import CryptoKit
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
    struct Presentation: Equatable {
        var frame: CGRect
        /// Global display coordinates. An empty clip hides the window without stopping its live layer.
        var clip: CGRect?
        /// Size animation is allowed only after the app has accepted this backing size.
        var resizeTo: CGSize? = nil
        /// Native popups still need workspace clipping, but their apps retain control of geometry.
        var locksBounds = true
    }

    struct Driver {
        var bounds: (CGWindowID) -> CGRect?
        var placed: ((CGWindowID) -> CGRect?)? = nil
        var submit: ([CGWindowID: Presentation], Set<CGWindowID>, Bool) -> Void
        var associated: (CGWindowID) -> [CGWindowID] = { _ in [] }
        var order: (CGWindowID, Int32, CGWindowID) -> Void = { _, _, _ in }

        static func load() -> Driver? {
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
            func symbol<T>(_ name: String, as: T.Type) -> T? {
                dlsym(library, name).map { unsafeBitCast($0, to: T.self) }
            }
            typealias Connection = @convention(c) () -> Int32
            typealias Bounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
            typealias Create = @convention(c) (Int32) -> Unmanaged<CFTypeRef>
            typealias Locked = @convention(c) (CFTypeRef, UInt32, CGRect) -> Void
            typealias Clear = @convention(c) (CFTypeRef, UInt32) -> Void
            typealias Clip = @convention(c) (CFTypeRef, UInt32, CFTypeRef?) -> Void
            typealias Region = @convention(c) (UnsafePointer<CGRect>, UnsafeMutablePointer<CFTypeRef?>) -> Int32
            typealias Commit = @convention(c) (CFTypeRef, Int32) -> Void
            typealias Associated = @convention(c) (Int32, UInt32) -> Unmanaged<CFArray>?
            typealias Order = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32
            guard let connection = symbol("SLSMainConnectionID", as: Connection.self),
                  let bounds = symbol("SLSGetWindowBounds", as: Bounds.self),
                  let create = symbol("SLSTransactionCreate", as: Create.self),
                  let locked = symbol("SLSTransactionSetWindowLockedBounds", as: Locked.self),
                  let clear = symbol("SLSTransactionClearWindowLockedBounds", as: Clear.self),
                  let clip = symbol("SLSTransactionSetWindowGlobalClipShape", as: Clip.self),
                  let region = symbol("CGSNewRegionWithRect", as: Region.self),
                  let commit = symbol("SLSTransactionCommit", as: Commit.self),
                  let associated = symbol("SLSCopyAssociatedWindows", as: Associated.self),
                  let order = symbol("SLSOrderWindow", as: Order.self) else { return nil }
            let cid = connection()
            return Driver(bounds: { id in
                var frame = CGRect.zero
                return bounds(cid, id, &frame) == 0 ? frame : nil
            }, placed: windowBounds, submit: { frames, released, synchronous in
                let transaction = create(cid).takeRetainedValue()
                for id in released {
                    clear(transaction, id)
                    clip(transaction, id, nil)
                }
                for (id, presentation) in frames {
                    if presentation.locksBounds {
                        locked(transaction, id, presentation.frame)
                    } else {
                        clear(transaction, id)
                    }
                    if var rect = presentation.clip {
                        var shape: CFTypeRef?
                        guard region(&rect, &shape) == 0, let shape else { continue }
                        clip(transaction, id, shape)
                    } else {
                        clip(transaction, id, nil)
                    }
                }
                commit(transaction, synchronous ? 1 : 0)
            }, associated: { id in
                associated(cid, id)?.takeRetainedValue() as? [CGWindowID] ?? []
            }, order: { id, mode, relative in _ = order(cid, id, mode, relative) })
        }
    }

    private let driver: Driver?
    // The compositor's thread submits; the main thread configures and reads how it went.
    private let lock = NSLock()
    private var presentations: [CGWindowID: Presentation] = [:]
    private var displayed: [CGWindowID: Presentation] = [:]
    private var families: [CGWindowID: Set<CGWindowID>] = [:]
    private var owned: Set<CGWindowID> = []
    private var excluded: Set<CGWindowID> = []
    private var appOwned: Set<CGWindowID> = []
    var controlledIDs: Set<CGWindowID> { lock.withLock { owned } }
    var controlledWindows: Int { lock.withLock { owned.count } }
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
        if failure != nil { return "macOS refused it, so windows stay where they are." }
        if driver == nil { return "Not available on this macOS." }
        if let authorizationFailure { return "Windows stay where they are: \(authorizationFailure)." }
        return nil
    }

    /// How long the window list takes to show a committed move; checked sooner, every move looks refused.
    private let settle: TimeInterval
    private var probing = false
    /// Turning the mode off and on again makes any check still out moot.
    private var epoch = 0

    init(driver: Driver? = .load(), settle: TimeInterval = 0.1) {
        self.driver = driver
        self.settle = settle
    }

    func configure(enabled: Bool) {
        guard lock.withLock({ () -> Bool in
            guard enabled != self.enabled else { return false }
            self.enabled = enabled
            if enabled { excluded = [] }
            checked = false
            refusal = nil
            probing = false
            epoch += 1
            return true
        }) else { return }
        if !enabled {
            releaseAll()
            liveScenes = false
        }
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
        if let unmet = Self.unmet {
            authorizationFailure = unmet
            onChange()
            return
        }
        authorizing = true
        authorizationFailure = nil
        onChange()
        let connection = String(Self.connectionID)
        let loader = resources.appendingPathComponent("tegi-dock-loader").path
        let grant = resources.appendingPathComponent("tegi-grant.dylib").path
        Self.admin.async { [weak self] in
            var problem: String?
            // Remembered: sudo runs the installed loader without asking.
            if Self.run("/usr/bin/sudo", ["-n", Self.installed, grant, connection]) != 0 {
                problem = Self.askOnce(loader: loader, grant: grant, connection: connection)
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

    private static let rule = "/etc/sudoers.d/tegi"
    /// Where only root can write, all the way up: sudo checks a file's hash and then runs it by path, so a loader the
    /// user could write could be swapped in between, and run as root.
    private static let installed = "/Library/PrivilegedHelperTools/tegi-dock-loader"
    /// Installing and removing the rule take turns, so one turned off mid-prompt is still removed.
    private static let admin = DispatchQueue(label: "tegi admin")
    /// Whether sudo lets tegi's loader run without a password. The way out is turning the mode off.
    static var remembered: Bool { FileManager.default.fileExists(atPath: rule) }

    /// What macOS must allow for the Dock helper to work, as yabai's needs, so no password is asked in vain.
    static var unmet: String? {
        typealias Get = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32
        var config: UInt32 = 0
        if let get = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csr_get_active_config") { _ = unsafeBitCast(get, to: Get.self)(&config) }
        // Unrestricted filesystem and task_for_pid.
        guard config & 0x6 == 0x6 else { return "it needs System Integrity Protection off" }
        // The helper is arm64e, as Dock is, and macOS runs no one else's arm64e code without one of these.
        var size = 0
        sysctlbyname("kern.bootargs", nil, &size, nil, 0)
        var args = [CChar](repeating: 0, count: size + 1)
        sysctlbyname("kern.bootargs", &args, &size, nil, 0)
        let boot = String(cString: args)
        guard boot.contains("-arm64e_preview_abi") || boot.contains("amfi_get_out_of_my_way=1") else {
            return "it needs the -arm64e_preview_abi boot argument"
        }
        return nil
    }

    /// One password prompt: install the loader where only root can write, grant now, and have sudo remember it so
    /// later launches don't ask. An update changes what the loader accepts, so it fails and the next launch asks again.
    private static func askOnce(loader: String, grant: String, connection: String) -> String? {
        guard let data = FileManager.default.contents(atPath: loader) else { return "the Dock helper is missing" }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let line = "\(sudoers(NSUserName())) ALL=(root) NOPASSWD: sha256:\(hash) \(sudoers(installed))"
        let script = [
            // The copy is checked against what tegi read, so a loader swapped in after that never runs.
            "/bin/mkdir -p -m 0755 /Library/PrivilegedHelperTools || exit 1",
            "copy=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.tegi.XXXXXX) || exit 1",
            "/bin/cat \(shell(loader)) > \"$copy\" && [ \"$(/usr/bin/shasum -a 256 \"$copy\" | /usr/bin/cut -d' ' -f1)\" = \(hash) ] && /bin/chmod 0755 \"$copy\" && /bin/mv -f \"$copy\" \(installed) || { /bin/rm -f \"$copy\"; exit 1; }",
            // A loader that couldn't grant isn't left installed with no rule to remove it by.
            "\(installed) \(shell(grant)) \(connection) || { /bin/rm -f \(installed); exit 1; }",
            // Drafted where only root can write, so nothing swaps it between the check and the install; and only a
            // rule visudo accepts goes in, since a broken one would lock sudo.
            "draft=$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.tegi.sudoers.XXXXXX) || exit 0",
            "printf '%s\\n' \(shell(line)) > \"$draft\" && /usr/sbin/visudo -cqf \"$draft\" && /usr/bin/install -m 0440 -o root -g wheel \"$draft\" \(rule)",
            "rm -f \"$draft\"; exit 0",
        ].joined(separator: "; ")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \(appleScript(script)) with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        return error[NSAppleScript.errorNumber] as? Int == -128 ? "the password prompt was cancelled" : "the Dock helper failed"
    }

    /// Removes the remembered rule and the installed loader, when the mode is off. The loader removes both itself; the
    /// password is only asked for when it can't, as with a rule from an older tegi, and only when `asking`: a launch
    /// never prompts, and `tegi msg state` shows what's left.
    static func forget(asking: Bool) {
        admin.async {
            guard remembered || FileManager.default.fileExists(atPath: installed) else { return }
            if run("/usr/bin/sudo", ["-n", installed, "forget"]) == 0 || !asking { return }
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \(appleScript("/bin/rm -f \(rule) \(installed)")) with administrator privileges")?.executeAndReturnError(&error)
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func shell(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScript(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// sudoers treats these as syntax in a user name or command path.
    private static func sudoers(_ word: String) -> String {
        word.reduce(into: "") { out, c in
            if " \t,:=\\#()".contains(c) { out.append("\\") }
            out.append(c)
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
    static var onFamilyChange: () -> Void = {}
    static var onGeometryChange: (CGWindowID) -> Void = { _ in }
    private static var watched: [CGWindowID] = []
    private static var observingOrder = false

    /// macOS only tells a process about windows it asks after, and each request replaces the last.
    static func watchOrder(of windows: [CGWindowID]) {
        let windows = windows.sorted()
        guard windows != watched, let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return }
        typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
        typealias Register = @convention(c) (Int32, Handler, UInt32, UnsafeMutableRawPointer?) -> Int32
        typealias Request = @convention(c) (Int32, UnsafePointer<UInt32>?, Int32) -> Int32
        guard let register = dlsym(library, "SLSRegisterConnectionNotifyProc"),
              let request = dlsym(library, "SLSRequestNotificationsForWindows") else { return }
        if !observingOrder {
            // 808 is the window server's "window ordered" event; its data starts with the window's number.
            let handler: Handler = { _, data, length, _ in
                guard let data, length >= 4 else { return }
                let window = data.loadUnaligned(as: UInt32.self)
                DispatchQueue.main.async { WindowServer.onReorder(window) }
            }
            _ = unsafeBitCast(register, to: Register.self)(connectionID, handler, 808, nil)
            let geometry: Handler = { _, data, length, _ in
                guard let data, length >= 4 else { return }
                let window = data.loadUnaligned(as: UInt32.self)
                DispatchQueue.main.async { WindowServer.onGeometryChange(window) }
            }
            for event: UInt32 in [806, 807] {
                _ = unsafeBitCast(register, to: Register.self)(connectionID, geometry, event, nil)
            }
            let family: Handler = { _, _, _, _ in
                DispatchQueue.main.async { WindowServer.onFamilyChange() }
            }
            // Space membership and parenting can change before Accessibility discovers a dialog.
            for event: UInt32 in [1325, 1326, 1341] {
                _ = unsafeBitCast(register, to: Register.self)(connectionID, family, event, nil)
            }
            observingOrder = true
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

    /// Acquiring freezes presentation before an app can answer a resize on its own thread.
    func manage(_ windows: Set<CGWindowID>, excluding excluded: Set<CGWindowID> = [], clips: [CGWindowID: CGRect] = [:], appOwned: Set<CGWindowID> = []) {
        guard active, let driver else { return }
        lock.withLock {
            self.excluded = excluded
            self.appOwned = appOwned
            // SkyLight returns an undirected group, including parents and siblings. Give the group one
            // stable representative so an attached window cannot also transform its parent.
            let associations = Dictionary(uniqueKeysWithValues: windows.map { ($0, Set(driver.associated($0)).subtracting(excluded).union([$0])) })
            let roots = Set(windows.filter { id in
                let candidates = associations[id]!.intersection(windows)
                return (candidates.subtracting(appOwned).min() ?? candidates.min()) == id
            })
            for id in presentations.keys where !roots.contains(id) { presentations[id] = nil }
            families = associations.filter { roots.contains($0.key) }.mapValues { $0.subtracting(roots) }
            for id in roots where presentations[id] == nil {
                if let frame = (driver.placed ?? driver.bounds)(id) {
                    presentations[id] = Presentation(frame: frame, clip: clips[id])
                }
            }
            for id in roots.intersection(appOwned) { presentations[id]?.clip = clips[id] }
            commit(presentations, synchronous: true)
        }
    }

    func contentBounds(of id: CGWindowID) -> CGRect? { driver?.bounds(id) }

    func presentation(of id: CGWindowID) -> Presentation? {
        lock.withLock {
            guard var presentation = displayed[id] else { return nil }
            if !presentation.locksBounds, let native = driver?.bounds(id) { presentation.frame = native }
            return presentation
        }
    }

    func refreshContent(of id: CGWindowID) {
        guard active else { return }
        lock.withLock {
            guard !excluded.contains(id) else { return }
            let root = presentations[id] != nil ? id : families.first { $0.value.contains(id) }?.key
            guard let root, let presentation = presentations[root] else { return }
            commit([root: presentation])
        }
    }

    func release(_ windows: Set<CGWindowID>) {
        guard let driver else { return }
        lock.withLock {
            excluded.formUnion(windows)
            for id in windows { presentations[id] = nil; families[id] = nil }
            for id in families.keys { families[id]?.subtract(windows) }
            let retained = Set(presentations.keys).union(families.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) })
            let released = owned.subtracting(retained)
            if !released.isEmpty { driver.submit([:], released, true) }
            owned.subtract(released)
            for id in released { displayed[id] = nil }
        }
    }

    func releaseAll() {
        guard let driver else { return }
        lock.withLock {
            if !owned.isEmpty { driver.submit([:], owned, true) }
            excluded.formUnion(owned)
            presentations = [:]
            displayed = [:]
            families = [:]
            appOwned = []
            owned = []
        }
    }

    /// The caller holds the lock, including across submission and release, so a stopped flight cannot retake a window.
    private func commit(_ changed: [CGWindowID: Presentation], synchronous: Bool = false) {
        guard let driver else { return }
        var batch = changed
        for (id, presentation) in changed {
            guard let bounds = driver.bounds(id) else { continue }
            if appOwned.contains(id) {
                batch[id]?.frame = bounds
                batch[id]?.locksBounds = false
                continue
            }
            let native = bounds.size
            let accepted = presentation.resizeTo.map {
                abs($0.width - native.width) <= 1 && abs($0.height - native.height) <= 1
            } ?? false
            if !accepted { batch[id]?.frame.size = native }
        }
        for id in changed.keys {
            guard let presentation = batch[id] else { continue }
            guard let children = families[id], !children.isEmpty,
                  let parent = driver.bounds(id), parent.width > 0, parent.height > 0 else { continue }
            let sx = presentation.frame.width / parent.width, sy = presentation.frame.height / parent.height
            for child in children {
                guard let frame = driver.bounds(child) else { continue }
                // Once the parent's native frame catches up, leaving a lock here would freeze the app's next popup redraw.
                batch[child] = Presentation(frame: CGRect(x: presentation.frame.minX + (frame.minX - parent.minX) * sx,
                                                          y: presentation.frame.minY + (frame.minY - parent.minY) * sy,
                                                          width: frame.width * sx, height: frame.height * sy), clip: presentation.clip,
                                            locksBounds: presentation.locksBounds && presentation.frame != parent)
            }
        }
        let retained = Set(presentations.keys).union(families.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) })
        let released = owned.subtracting(retained)
        guard !batch.isEmpty || !released.isEmpty else { return }
        let start = CACurrentMediaTime()
        driver.submit(batch, released, synchronous)
        for id in released { displayed[id] = nil }
        displayed.merge(batch) { _, new in new }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        owned = retained
        commits += 1
        commitMS += elapsed
        peakMS = max(peakMS, elapsed)
    }

    func submit(_ frames: [CGWindowID: Presentation]) {
        guard let driver, !frames.isEmpty, active else { return }
        let placed = driver.placed ?? driver.bounds
        var probe: (CGWindowID, CGPoint)?
        let probeEpoch = lock.withLock { () -> Int in
            guard enabled, refusal == nil else { return epoch }
            let attached = families.values.reduce(into: Set<CGWindowID>()) { $0.formUnion($1) }
            let roots = frames.filter { !attached.contains($0.key) && !excluded.contains($0.key) }
            guard !roots.isEmpty else { return epoch }
            if !checked && !probing {
                for (id, presentation) in roots {
                    guard let from = placed(id), from.origin != presentation.frame.origin,
                          Self.onDisplay(presentation.frame), presentation.clip?.isEmpty != true else { continue }
                    probe = (id, from.origin)
                    probing = true
                    break
                }
            }
            presentations.merge(roots) { _, new in new }
            commit(roots)
            return epoch
        }
        guard let (id, from) = probe else { return }
        let check = { [self] in
            let actual = placed(id)
            let refused = lock.withLock { () -> Bool? in
                guard probeEpoch == epoch else { return nil }
                probing = false
                guard let actual else { return nil }
                let stayed = abs(actual.minX - from.x) < 1 && abs(actual.minY - from.y) < 1
                if stayed { refusal = "macOS refused presentation control" } else { checked = true }
                return stayed
            }
            if refused == true { DispatchQueue.main.async { [self] in
                liveScenes = false
                onRefused()
            } }
        }
        if settle == 0 { check() } else { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + settle, execute: check) }
    }
}
