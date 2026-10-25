import AppKit
import SwiftUI
import TegiCore

final class HotkeyOverlay {
    private var panel: NSPanel?
    private var monitors: [Any] = []

    private static let sections: [(String, [(String, [Command])])] = [
        ("Move around", [
            ("Focus column left, right", [.focusColumnLeft, .focusColumnRight]),
            ("Focus window down, up", [.focusWindowDown, .focusWindowUp]),
            ("Focus workspace down, up", [.focusWorkspaceDown, .focusWorkspaceUp]),
            ("Overview", [.toggleOverview]),
            ("Recent windows", [.nextWindow(sameApp: false)]),
        ]),
        ("Rearrange", [
            ("Move column left, right", [.moveColumnLeft, .moveColumnRight]),
            ("Move window down, up", [.moveWindowDown, .moveWindowUp]),
            ("Send column to workspace down, up", [.moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp]),
            ("Put window in column left, right", [.consumeOrExpelWindowLeft, .consumeOrExpelWindowRight]),
        ]),
        ("Size and windows", [
            ("Switch column width", [.switchPresetColumnWidth]),
            ("Maximize column", [.maximizeColumn]),
            ("Fullscreen", [.fullscreenWindow]),
            ("Float or tile", [.toggleWindowFloating]),
            ("Close window", [.closeWindow]),
        ]),
    ]

    var isVisible: Bool { panel != nil }

    func toggle(_ config: Config) {
        isVisible ? hide() : show(config)
    }

    func show(_ config: Config) {
        hide()
        func keys(_ c: Command) -> String? { config.binds.filter { $0.value == c }.map { $0.key.symbol(hyper: config.mod) }.sorted().first }
        let sections = Self.sections.map { title, rows in
            CheatSheet.Section(title: title, rows: rows.compactMap { label, commands in
                let caps = commands.compactMap(keys)
                return caps.count == commands.count ? CheatSheet.Row(label: label, keys: caps) : nil
            })
        }.filter { !$0.rows.isEmpty }
        let hint = keys(.showHotkeyOverlay).map { "\($0) shows this again · any key closes it" }
        let host = NSHostingView(rootView: CheatSheet(sections: sections, hint: hint))

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: (f.midX - panel.frame.width / 2).rounded(), y: (f.midY - panel.frame.height / 2).rounded()))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }].compactMap { $0 }
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The shortcuts in columns on frosted glass, with the mascot peeking over the top.
private struct CheatSheet: View {
    struct Row { let label: String; let keys: [String] }
    struct Section { let title: String; let rows: [Row] }
    let sections: [Section]
    let hint: String?

    var body: some View {
        ZStack(alignment: .top) {
            Mascot(ringWidth: 0, radius: 7).frame(width: 28, height: 32)
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 30) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(section.title.uppercased())
                                .font(.system(size: 10.5, weight: .bold, design: .rounded)).tracking(0.4)
                                .foregroundStyle(.secondary)
                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    GridRow {
                                        HStack(spacing: 4) { ForEach(row.keys, id: \.self) { KeyCap(text: $0) } }
                                            .gridColumnAlignment(.trailing)
                                        Text(row.label).font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    }
                                }
                            }
                        }
                    }
                }
                if let hint {
                    Text(hint).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.top, 18)
        }
        .fixedSize()
    }
}
