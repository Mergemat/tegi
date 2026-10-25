import AppKit
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
    var onRestart: () -> Void = {}

    static var needed: Bool {
        !AXIsProcessTrusted() || (!CGPreflightScreenCaptureAccess() && !UserDefaults.standard.bool(forKey: "skippedScreenRecording"))
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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 480),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        chrome(window)
        window.isReleasedWhenClosed = false
        // It can't be minimized or resized, so their greyed-out buttons would only look broken.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentViewController = hosting(WelcomeView(permissions: permissions, done: { [weak self] in
            self?.close()
        }, restart: { [weak self] in self?.onRestart() }))
        window.center()
        return window
    }

    private func close() {
        if !permissions.screen { UserDefaults.standard.set(true, forKey: "skippedScreenRecording") }
        permissions.stop()
        window?.close()
    }
}

struct WelcomeView: View {
    @ObservedObject var permissions: Permissions
    @Environment(\.colorScheme) private var scheme
    let done: () -> Void
    let restart: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        let t = Theme(scheme)
        VStack(spacing: 0) {
            Image(nsImage: tegiIcon).resizable().frame(width: 104, height: 104)
                .shadow(color: tegiBlue.opacity(0.45), radius: 18, y: 6)
                .padding(.top, 40)
            Text("Hi, I'm tegi!").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(t.text).padding(.top, 10)
            Text("Two quick permissions and your windows start tiling.")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(t.secondary).padding(.top, 4).padding(.bottom, 22)

            Card {
                PermissionRow(title: "Accessibility", detail: "To move and resize your windows.", granted: permissions.accessibility) {
                    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(prompt)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                PermissionRow(title: "Screen Recording", detail: "For smooth slides and the overview. Optional.", granted: permissions.screen,
                              last: !(permissions.screen && !permissions.screenAtLaunch) && !Bundle.main.bundlePath.hasPrefix("/Applications/")) {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                if permissions.screen && !permissions.screenAtLaunch {
                    Row(title: "One restart to go", detail: "macOS applies Screen Recording after a restart.",
                        last: !Bundle.main.bundlePath.hasPrefix("/Applications/")) {
                        Button("Restart tegi", action: restart).buttonStyle(GummyButtonStyle())
                    }
                }
                if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    Row(title: "Start at login", detail: "Tiled from the moment you log in.", last: true) {
                        GummyToggle(isOn: login) { on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                            login = SMAppService.mainApp.status == .enabled
                        }
                    }
                }
            }

            Spacer(minLength: 16)
            Button(action: done) {
                Text(permissions.accessibility ? "Start tiling" : "Waiting for Accessibility…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(GummyButtonStyle(prominent: permissions.accessibility))
            .disabled(!permissions.accessibility)
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.page)
        }
        .frame(width: 480, height: 480)
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
