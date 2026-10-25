import AppKit
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

        let grid = NSGridView()
        grid.rowSpacing = 7
        grid.columnSpacing = 16
        for (title, rows) in Self.sections {
            let rows = rows.filter { $0.1.allSatisfy { keys($0) != nil } }
            guard !rows.isEmpty else { continue }
            if grid.numberOfRows > 0 { grid.addRow(with: [NSGridCell.emptyContentView]).height = 6 }
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            grid.addRow(with: [NSGridCell.emptyContentView, header])
            for (label, commands) in rows {
                let caps = NSStackView(views: commands.compactMap(keys).map(Keycap.init))
                caps.spacing = 4
                let text = NSTextField(labelWithString: label)
                text.font = .systemFont(ofSize: 14)
                text.textColor = .labelColor
                grid.addRow(with: [caps, text])
            }
        }
        if let again = keys(.showHotkeyOverlay) {
            let hint = NSTextField(labelWithString: "\(again) shows this again; any key closes it")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            grid.addRow(with: [NSGridCell.emptyContentView]).height = 6
            grid.addRow(with: [NSGridCell.emptyContentView, hint])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        let container = Background()
        container.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        panel.setContentSize(container.fittingSize)
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

private final class Background: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor(white: 0.12, alpha: 1).setFill()
        shape.fill()
        NSColor(white: 1, alpha: 0.1).setStroke()
        shape.stroke()
    }
}

private final class Keycap: NSView {
    private let text: NSAttributedString

    init(_ symbol: String) {
        text = NSAttributedString(string: symbol, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = text.size()
        return NSSize(width: max(26, ceil(s.width) + 14), height: ceil(s.height) + 6)
    }

    override var firstBaselineOffsetFromTop: CGFloat { 3 + NSFont.systemFont(ofSize: 13, weight: .medium).ascender }

    override func draw(_ dirtyRect: NSRect) {
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }
}
