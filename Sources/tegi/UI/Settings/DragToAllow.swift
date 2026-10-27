import AppKit
import SwiftUI

/// The System Settings pages where an app is allowed by dragging it into a list.
enum PrivacyPane {
    case accessibility, screenRecording

    var title: String {
        switch self {
        // macOS 27 renamed the page; its URL stayed the same.
        case .accessibility: ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            ? "Device Control and Data Access" : "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    var url: URL {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

/// Opens a privacy page with tegi docked over its window, ready to drag into the list.
final class DragToAllow {
    private(set) var pane: PrivacyPane?
    private var panel: NSPanel?
    private var timer: Timer?
    private var found = false
    var onBack: () -> Void = {}

    func show(_ pane: PrivacyPane) {
        hide()
        self.pane = pane
        NSWorkspace.shared.open(pane.url)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = FirstMouseHostingView(rootView: DragToAllowView(pane: pane, dragging: { [weak panel] on in
            // A drop let go over the panel would land on tegi, not on System Settings below it.
            panel?.ignoresMouseEvents = on
        }, back: { [weak self] in
            self?.hide()
            self?.onBack()
        }))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        self.panel = panel
        // Without Accessibility, which this may be asking for, nothing tells tegi where System Settings moves.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.follow() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        pane = nil
        found = false
    }

    private func follow() {
        guard let panel else { return }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
            // Quit by the user, as closing its window does; before that, it may still be launching.
            if found { hide() }
            return
        }
        // Still opening, minimized, or on another Space.
        guard let (number, frame) = Self.window(of: settings.processIdentifier) else { return panel.orderOut(nil) }
        found = true
        // Docked to the right edge, it covers the list's column, not the sidebar, whatever the sidebar's width.
        panel.setFrameOrigin(CGPoint(x: frame.maxX - panel.frame.width - 16, y: frame.minY + 16))
        // Just above System Settings, as a sheet would be: its password prompt and other apps' windows stay over it.
        panel.order(.above, relativeTo: number)
    }

    /// An app's main window, in AppKit coordinates: its largest, since its prompts are windows of their own.
    private static func window(of pid: pid_t) -> (Int, CGRect)? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let frames = windows.compactMap { info -> (Int, CGRect)? in
            guard info[kCGWindowOwnerPID] as? pid_t == pid, info[kCGWindowLayer] as? Int == 0, let number = info[kCGWindowNumber] as? Int,
                  let bounds = info[kCGWindowBounds].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) }) else { return nil }
            return (number, bounds)
        }
        guard let (number, bounds) = frames.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }),
              let primary = NSScreen.screens.first else { return nil }
        return (number, CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height))
    }
}

/// The panel isn't key, and without this the first click only makes it so.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DragToAllowView: View {
    let pane: PrivacyPane
    let dragging: (Bool) -> Void
    let back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to tegi")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(tegiBlue)
                    Text("Drag ").foregroundStyle(.secondary) + Text("tegi").bold()
                        + Text(" to the list above to allow ").foregroundStyle(.secondary) + Text(pane.title).bold()
                }
                .font(.system(size: 12.5, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(nsImage: tegiIcon).resizable().frame(width: 28, height: 28)
                    Text("tegi").font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
                .overlay(DragSource(dragging: dragging))
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Hands System Settings the app the way Finder does: as the bundle's file URL.
private struct DragSource: NSViewRepresentable {
    let dragging: (Bool) -> Void

    func makeNSView(context: Context) -> View { View(dragging: dragging) }
    func updateNSView(_ view: View, context: Context) {}

    final class View: NSView, NSDraggingSource {
        let dragging: (Bool) -> Void

        init(dragging: @escaping (Bool) -> Void) {
            self.dragging = dragging
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            let at = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(CGRect(x: at.x - 20, y: at.y - 20, width: 40, height: 40), contents: tegiIcon)
            beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
            dragging(true)
        }

        func draggingSession(_: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic, .link] : []
        }

        func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) { dragging(false) }
    }
}
