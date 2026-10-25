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
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: WelcomeView(permissions: permissions, done: { [weak self] in
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
    let done: () -> Void
    let restart: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: tegiIcon).resizable().frame(width: 120, height: 120)
                .shadow(color: tegiBlue.opacity(0.35), radius: 18, y: 6)
                .padding(.top, 34)
            Text("Hi, I'm tegi!").font(.system(size: 30, weight: .bold)).padding(.top, 10)
            Text("Two quick permissions and your windows start tiling.")
                .foregroundStyle(.secondary).padding(.top, 4)

            VStack(spacing: 12) {
                PermissionRow(symbol: "hand.raised.fill", tint: SwiftUI.Color(red: 0.42, green: 0.7, blue: 1),
                              title: "Accessibility", detail: "To move and resize your windows.", granted: permissions.accessibility) {
                    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(prompt)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                PermissionRow(symbol: "rectangle.dashed.badge.record", tint: SwiftUI.Color(red: 1, green: 0.5, blue: 0.72),
                              title: "Screen Recording", detail: "For smooth workspace slides and the overview. Optional.",
                              granted: permissions.screen) {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                if permissions.screen && !permissions.screenAtLaunch {
                    HStack {
                        Text("macOS applies Screen Recording after a restart.").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart tegi", action: restart)
                    }
                    .padding(.horizontal, 6)
                }
                if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                    HStack(spacing: 12) {
                        Tile(symbol: "sunrise.fill", tint: SwiftUI.Color(red: 1, green: 0.66, blue: 0.3), size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start at login").font(.system(size: 14, weight: .semibold))
                            Text("So your windows are tiled from the moment you log in.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { login }, set: { on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                            login = SMAppService.mainApp.status == .enabled
                        }))
                        .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(14)
                    .background(SwiftUI.Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)

            Spacer(minLength: 20)
            Button(action: done) {
                Text(permissions.accessibility ? "Start tiling" : "Waiting for Accessibility…")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!permissions.accessibility)
            .padding(.horizontal, 30)
            .padding(.bottom, 28)
        }
        .frame(width: 520, height: 600)
        .fontDesign(.rounded)
        .tint(tegiBlue)
        .animation(.spring(duration: 0.35), value: permissions.accessibility)
        .animation(.spring(duration: 0.35), value: permissions.screen)
    }
}

struct PermissionRow: View {
    let symbol: String
    let tint: SwiftUI.Color
    let title: String
    let detail: String
    let granted: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Tile(symbol: symbol, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color(red: 0.3, green: 0.78, blue: 0.5))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button("Allow…", action: allow)
            }
        }
        .padding(14)
        .background(SwiftUI.Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(granted ? SwiftUI.Color(red: 0.3, green: 0.78, blue: 0.5).opacity(0.5) : SwiftUI.Color.primary.opacity(0.07)))
    }
}
