import AppKit
import ServiceManagement
import TegiCore
import UniformTypeIdentifiers

let configURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/tegi/config")
let defaultsURL = configURL.deletingLastPathComponent().appending(path: "defaults")
let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
// The Homebrew command is a symlink into the app, so the bundle is found from the resolved path.
let version = (Bundle.main.executableURL?.resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    .flatMap(Bundle.init(url:))?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var wm: WindowManager?
    private var hotkeys: Hotkeys?
    private let overlay = HotkeyOverlay()
    private let banner = Banner()
    private var streamQueued = false
    private var ipc: IPC.Server?
    private var config: Config?
    private var configText: String?
    private var firstRun = false
    private var problems: [String] = []
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var signals: [DispatchSourceSignal] = []
    private let welcome = WelcomeWindow()
    private lazy var settingsModel: SettingsModel = {
        let model = SettingsModel(url: configURL)
        model.onPermissions = { [weak self] in self?.welcome.show() }
        model.onRecording = { [weak self] recording in
            guard let self else { return }
            if recording { hotkeys?.unregisterAll() } else if let wm { bind(wm.config) }
        }
        return model
    }()
    private lazy var settings = SettingsWindow(model: settingsModel)

    func applicationDidFinishLaunching(_: Notification) {
        status.menu = NSMenu()
        status.menu?.delegate = self
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.quit() }
            source.resume()
            signals.append(source)
        }
        welcome.onRestart = { [weak self] in self?.relaunch() }
        if WelcomeWindow.needed { welcome.show() }
        startWhenTrusted()
    }

    private func startWhenTrusted() {
        guard AXIsProcessTrusted() else {
            problems = ["Needs Accessibility access to move windows"]
            refresh()
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let self, self.wm == nil, AXIsProcessTrusted() else { return }
                    self.start()
                }
            }
            return
        }
        start()
    }

    private func start() {
        // The default is 6 s, long enough for one hung app to freeze its windows.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
        reloadConfig()
        let wm = WindowManager(config: config ?? .builtIn)
        wm.onChange = { [weak self] in
            self?.refresh()
            self?.queueEvent()
        }
        wm.onQuit = { [weak self] in self?.quit() }
        wm.onSettings = { [weak self] pane in self?.showSettings(pane) }
        wm.onHotkeyOverlay = { [weak self] in
            guard let self, let wm = self.wm else { return }
            overlay.toggle(wm.config)
        }
        self.wm = wm
        hotkeys = Hotkeys { [weak self] command in
            if command != .showHotkeyOverlay { self?.overlay.hide() }
            self?.wm?.run(command)
        }
        bind(wm.config)
        wm.start()
        ipc = IPC.Server { [weak self] in self?.handle($0) ?? "error: tegi is starting" }
        watchConfig()
        refresh()
        if firstRun {
            if installed { try? SMAppService.mainApp.register() }
            overlay.show(wm.config)
            banner.show("Created a config at ~/.config/tegi/config", for: 8)
        }
    }

    private func reloadConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) {
            try? Config.starterText.write(to: configURL, atomically: true, encoding: .utf8)
            firstRun = true
        }
        if (try? String(contentsOf: defaultsURL, encoding: .utf8)) != Config.defaultsText {
            try? Config.defaultsText.write(to: defaultsURL, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            problems = ["Can't read \(configURL.path)"]
            return
        }
        guard text != configText else { return }
        configText = text
        do {
            config = try Config.parse(text)
            problems = []
            banner.hide(animated: true)
        } catch {
            problems = ["Config \(error); using the last good one"]
            banner.show("Config \(error). The last good config is still in use.")
        }
    }

    private func bind(_ config: Config) {
        guard wm?.paused != true else { return }
        let refused = hotkeys?.register(config.binds) ?? []
        if !refused.isEmpty {
            problems.append("Taken by another app: " + refused.map(\.description).sorted().joined(separator: ", "))
        }
    }

    private func configChanged() {
        watchConfig()
        let before = config
        reloadConfig()
        if let wm, let config, config != before {
            bind(config)
            wm.update(config)
        }
        settingsModel.reload()
        refresh()
    }

    private func watchConfig() {
        watchers.forEach { $0.cancel() }
        watchers = [configURL.deletingLastPathComponent(), configURL].compactMap { url in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
            source.setEventHandler { [weak self] in self?.configChanged() }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func handle(_ request: String) -> String {
        let words = request.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let wm else { return "error: tegi is waiting for Accessibility access" }
        switch words.first {
        case "ping":
            return "ok"
        case "state":
            let data = try? JSONSerialization.data(withJSONObject: wm.state(), options: [.prettyPrinted, .sortedKeys])
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "error: couldn't encode state"
        case "event-stream":
            return compactState() ?? "error: couldn't encode state"
        case "action":
            guard let command = Command(words.dropFirst()) else {
                return "error: unknown action \(words.dropFirst().joined(separator: " "))"
            }
            if command != .showHotkeyOverlay { overlay.hide() }
            wm.run(command)
            return "ok"
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.quit() }
            return "ok"
        default:
            return "error: use action <command>, state, event-stream or quit"
        }
    }

    private func compactState() -> String? {
        guard let wm, let data = try? JSONSerialization.data(withJSONObject: wm.state(), options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func queueEvent() {
        guard !streamQueued else { return }
        streamQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            streamQueued = false
            if let line = compactState() { ipc?.broadcast(line) }
        }
    }

    private func refresh() {
        guard let wm else {
            status.button?.title = "tegi ⚠︎"
            return
        }
        let w = wm.world
        var workspace = "1"
        if w.monitors.indices.contains(w.focusedMonitor) {
            let mon = w.monitors[w.focusedMonitor]
            workspace = mon.workspaces[mon.active].name ?? "\(mon.active + 1)"
        }
        let label = wm.paused ? "tegi ⏸" : workspace
        status.button?.title = problems.isEmpty ? label : "\(label) ⚠︎"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in problems + [wm?.timing].compactMap({ $0 }) {
            menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        if wm?.threeFingerConflict == true {
            menu.addItem(NSMenuItem(title: "macOS also uses three-finger swipes: set Trackpad > More Gestures to four fingers", action: nil, keyEquivalent: ""))
            menu.addItem(item("Open Trackpad Settings…", #selector(openTrackpad)))
        }
        if wm?.canCapture == false {
            menu.addItem(NSMenuItem(title: "Workspace slides and overview pictures need Screen Recording", action: nil, keyEquivalent: ""))
            menu.addItem(item("Open Screen Recording Settings…", #selector(openScreenRecording)))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        if let wm {
            menu.addItem(item("Overview", #selector(toggleOverview)))
            menu.addItem(item("Show Hotkeys", #selector(showHotkeys)))
            menu.addItem(item(wm.paused ? "Resume Tiling" : "Pause Tiling", #selector(togglePause)))
        } else {
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        }
        if installed {
            let login = item("Start at Login", #selector(toggleLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(item("Settings…", #selector(showSettingsFromMenu), key: ","))
        menu.addItem(item("Open Config", #selector(openConfig)))
        menu.addItem(item("Open Defaults", #selector(openDefaults)))
        menu.addItem(.separator())
        menu.addItem(item("Quit tegi", #selector(quitFromMenu), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        guard let wm else { return }
        wm.setPaused(!wm.paused)
        if wm.paused {
            hotkeys?.unregisterAll()
        } else {
            bind(wm.config)
        }
        refresh()
    }

    @objc private func toggleOverview() { wm?.run(.toggleOverview) }

    @objc private func showSettingsFromMenu() { showSettings(nil) }

    private func showSettings(_ pane: String?) {
        if let pane, Pane(rawValue: pane) != nil { UserDefaults.standard.set(pane, forKey: "settings.pane") }
        settings.show()
    }

    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        quit()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            banner.show("Couldn't change Start at Login: \(error.localizedDescription)", for: 6)
        }
    }

    @objc private func showHotkeys() {
        if let wm { overlay.show(wm.config) }
    }

    @objc private func openConfig() { edit(configURL) }
    @objc private func openDefaults() { edit(defaultsURL) }

    private func edit(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openTrackpad() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quitFromMenu() { quit() }

    private func quit() {
        if wm?.paused == false { wm?.restore() }
        ipc?.stop()
        exit(0)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage: tegi                    run the window manager
       tegi msg action <cmd>   run a command, e.g. tegi msg action focus-column-left
       tegi msg state          print workspaces and windows as JSON
       tegi msg event-stream   print the same as one line on every change
       tegi msg quit           quit, putting hidden windows back on screen
       tegi validate [file]    check a config file
       tegi --version          print the version
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil:
    let lockFile = open((NSTemporaryDirectory() as NSString).appendingPathComponent("tegi.lock"), O_CREAT | O_RDWR, 0o600)
    if lockFile < 0 || flock(lockFile, LOCK_EX | LOCK_NB) != 0 { fail("tegi is already running") }
    signal(SIGPIPE, SIG_IGN)
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
case "msg" where args == ["msg", "event-stream"]:
    if !IPC.stream("event-stream") { fail("tegi isn't running") }
case "msg" where args.count >= 2:
    guard let reply = IPC.send(args.dropFirst().joined(separator: " ")) else { fail("tegi isn't running") }
    if reply.hasPrefix("error") { fail(reply) }
    print(reply)
case "validate":
    let url = args.count > 1 ? URL(fileURLWithPath: args[1]) : configURL
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { fail("can't read \(url.path)") }
    do {
        _ = try Config.parse(text)
        print("\(url.path) is valid")
    } catch {
        fail("\(url.path): \(error)")
    }
case "--version", "version":
    print("tegi \(version)")
case "--help", "-h", "help":
    print(usage)
default:
    fail(usage)
}
