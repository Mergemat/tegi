import AppKit
import Combine
import ServiceManagement
import SwiftUI

final class Permissions: ObservableObject {
    @Published var accessibility = AXIsProcessTrusted()
    @Published var screen = CGPreflightScreenCaptureAccess()
    let screenAtLaunch = CGPreflightScreenCaptureAccess()
    private var timer: Timer?

    func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let ax = AXIsProcessTrusted()
            DispatchQueue.global(qos: .utility).async {
                let screen = CGPreflightScreenCaptureAccess()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.accessibility != ax { self.accessibility = ax }
                    if self.screen != screen { self.screen = screen }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

final class WelcomeWindow {
    private var window: NSWindow?
    private let permissions = Permissions()
    private let model: SettingsModel
    private let dragToAllow = DragToAllow()
    private var granted: AnyCancellable?
    var onRestart: () -> Void = {}
    var onClose: () -> Void = {}

    init(model: SettingsModel) {
        self.model = model
        dragToAllow.onBack = { [weak self] in self?.show() }
        // Only a grant brings tegi back: a drag can miss the list, and then the user is still needed in System Settings.
        granted = permissions.$accessibility.combineLatest(permissions.$screen).sink { [weak self] accessibility, screen in
            guard let self, let pane = dragToAllow.pane, pane == .accessibility ? accessibility : screen else { return }
            dragToAllow.hide()
            show()
        }
    }

    /// Tiling waits for "Start tiling", even across the restart macOS asks for once Screen Recording is on.
    static var needed: Bool {
        !UserDefaults.standard.bool(forKey: "onboarded") || !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess()
    }

    func show() {
        permissions.watch()
        let window = self.window ?? make()
        self.window = window
        // Opened by a hotkey or the command line, tegi isn't the active app, and a plain activate leaves it behind.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func make() -> NSWindow {
        let window = FloatingPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 480),
                                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        chrome(window)
        window.isReleasedWhenClosed = false
        // It can't be minimized or resized, so their greyed-out buttons would only look broken.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = hosting(WelcomeView(permissions: permissions, allow: { [weak self] pane in
            self?.dragToAllow.show(pane)
        }, done: { [weak window] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            window?.close()
        }, restart: { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            self?.onRestart()
        }).environmentObject(model))
        window.center()
        // The close button is as good as "Start tiling", which tegi still only does with both permissions.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.closed()
        }
        return window
    }

    private func closed() {
        dragToAllow.hide()
        permissions.stop()
        onClose()
    }
}

struct WelcomeView: View {
    @ObservedObject var permissions: Permissions
    @EnvironmentObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    let allow: (PrivacyPane) -> Void
    let done: () -> Void
    let restart: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled
    // Offered only where it can work: on most Macs SIP is on, and the row would only be a way to a password prompt that fails.
    private let direct = WindowServer.unmet == nil

    var body: some View {
        let t = Theme(scheme)
        let restarting = permissions.screen && !permissions.screenAtLaunch
        VStack(spacing: 0) {
            Image(nsImage: tegiIcon).resizable().frame(width: 104, height: 104)
                .shadow(color: tegiBlue.opacity(0.45), radius: 18, y: 6)
                .padding(.top, 40)
            Text("Hi, I'm tegi!").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(t.text).padding(.top, 10)
            Text("Two quick permissions and your windows start tiling.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(t.secondary).padding(.top, 4).padding(.bottom, 22)

            Card {
                PermissionRow(title: PrivacyPane.accessibility.title, detail: "To move and resize your windows.", granted: permissions.accessibility) {
                    allow(.accessibility)
                }
                PermissionRow(title: PrivacyPane.screenRecording.title,
                              detail: restarting ? "macOS applies it once tegi restarts." : "For smooth slides and the overview.",
                              granted: permissions.screen, last: !direct && !installed) {
                    allow(.screenRecording)
                }
                if direct {
                    ToggleRow(title: "Direct mode",
                              detail: model.motionProblem ?? "Smoother motion and a live overview, since SIP is off. Asks for your password once.",
                              key: ["window-server-motion"], isOn: model.shown.animations.windowServer, last: !installed, on: ["on"], off: ["off"])
                }
                if installed {
                    Row(title: "Start at login", detail: "Tiled from the moment you log in.", last: true) {
                        GummyToggle(isOn: login) { on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                            login = SMAppService.mainApp.status == .enabled
                        }
                    }
                }
            }

            let ready = permissions.accessibility && permissions.screen
            Button(action: restarting ? restart : done) {
                Text(!ready ? "Allow both to start tiling" : restarting ? "Restart and start tiling" : "Start tiling")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(GummyButtonStyle(prominent: ready))
            .disabled(!ready)
            .padding(.horizontal, Space.page)
            .padding(.top, 8)
            .padding(.bottom, Space.page)
        }
        // As tall as its rows, which come and go with permissions; the window follows.
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                t.background
                if t.night { Stars() }
            }
            .ignoresSafeArea()
        }
        .animation(.spring(duration: 0.35), value: permissions.accessibility)
        .animation(.spring(duration: 0.35), value: permissions.screen)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var last = false
    let allow: () -> Void

    var body: some View {
        Row(title: title, detail: detail, last: last) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(SwiftUI.Color(hex: 0x3fcf8e))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…", action: allow).buttonStyle(GummyButtonStyle(prominent: true))
            }
        }
    }
}
