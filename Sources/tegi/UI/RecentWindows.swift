import AppKit
import QuartzCore
import TegiCore

final class RecentWindows {
    struct Item {
        var id: WindowID
        var title: String
        var app: String
        var image: IOSurface?
        var icon: NSImage?
        var size: CGSize
    }

    var onCommit: (WindowID) -> Void = { _ in }
    private var order: [WindowID] = []
    private var pending: DispatchWorkItem?
    private var session: (items: [Item], selected: Int, modifiers: NSEvent.ModifierFlags)?
    private var panel: SwitcherPanel?
    private var monitors: [Any] = []

    var isOpen: Bool { session != nil }

    func focused(_ id: WindowID) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit(id) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func commit(_ id: WindowID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    func forget(_ id: WindowID) { order.removeAll { $0 == id } }

    func ordered(_ ids: [WindowID]) -> [WindowID] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.sorted { (rank[$0] ?? .max, $0) < (rank[$1] ?? .max, $1) }
    }

    func previous(than current: WindowID?, among ids: Set<WindowID>) -> WindowID? {
        order.first { $0 != current && ids.contains($0) }
    }

    func open(_ items: [Item], forward: Bool) {
        guard items.count > 1 else { return }
        let held = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift])
        guard !held.isEmpty else {
            let id = items[forward ? 1 : items.count - 1].id
            commit(id)
            return onCommit(id)
        }
        session = (items, forward ? 1 : items.count - 1, held)
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in self?.modifiersChanged() }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .flagsChanged { modifiersChanged() } else { key(e.keyCode) }
            return nil
        }
        monitors = [flags, local].compactMap { $0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let s = session else { return }
            let panel = SwitcherPanel()
            panel.show(s.items, selected: s.selected)
            self.panel = panel
        }
    }

    func setImage(_ image: IOSurface, for id: WindowID) {
        guard var s = session, let i = s.items.firstIndex(where: { $0.id == id }) else { return }
        s.items[i].image = image
        session = s
        panel?.show(s.items, selected: s.selected)
    }

    func step(_ delta: Int) {
        guard var s = session else { return }
        s.selected = (s.selected + delta + s.items.count) % s.items.count
        session = s
        panel?.show(s.items, selected: s.selected)
    }

    func handle(_ command: Command, binds: [KeyCombo: Command]) -> Bool {
        switch command {
        case .nextWindow: step(1)
        case .previousWindow: step(-1)
        case .focusColumnRight, .focusColumnRightOrFirst: step(1)
        case .focusColumnLeft, .focusColumnLeftOrLast: step(-1)
        case .focusColumnFirst: step(-(session?.selected ?? 0))
        case .focusColumnLast: step((session?.items.count ?? 1) - 1 - (session?.selected ?? 0))
        default: return false
        }
        return true
    }

    private func modifiersChanged() {
        guard let s = session else { return }
        if NSEvent.modifierFlags.intersection(s.modifiers).isEmpty { finish(commit: true) }
    }

    private func key(_ code: UInt16) {
        switch code {
        case 53: finish(commit: false)
        case 36: finish(commit: true)
        case 123: step(-1)
        case 124: step(1)
        default: break
        }
    }

    private func finish(commit: Bool) {
        guard let s = session else { return }
        session = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        if commit {
            let id = s.items[s.selected].id
            self.commit(id)
            onCommit(id)
        }
    }
}

private final class SwitcherPanel: NSPanel {
    private let root = CALayer()
    private let label = CATextLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(root)
        contentView = view
        root.backgroundColor = CGColor(gray: 0.12, alpha: 0.96)
        root.cornerRadius = 16
        root.borderWidth = 1
        root.borderColor = CGColor(gray: 1, alpha: 0.1)
        label.fontSize = 14
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.foregroundColor = CGColor(gray: 0.95, alpha: 1)
        label.alignmentMode = .center
        label.truncationMode = .end
    }

    func show(_ items: [RecentWindows.Item], selected: Int) {
        guard let screen = NSScreen.main else { return }
        label.contentsScale = screen.backingScaleFactor
        let visible = screen.visibleFrame
        let maxHeight = min(480, visible.height * 0.5)
        var sizes = items.map { item -> CGSize in
            let scale = min(0.5, maxHeight / max(item.size.height, 1))
            return CGSize(width: item.size.width * scale, height: item.size.height * scale)
        }
        let pad = 16.0, spacing = 20.0
        let total = sizes.reduce(0) { $0 + $1.width } + spacing * Double(max(items.count - 1, 0)) + pad * 4
        let fit = min(1, visible.width * 0.92 / total)
        sizes = sizes.map { CGSize(width: ($0.width * fit).rounded(), height: ($0.height * fit).rounded()) }
        let rowHeight = sizes.map(\.height).max() ?? 0
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * Double(max(items.count - 1, 0)) + pad * 4
        let height = rowHeight + pad * 4 + 34
        setFrame(CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height), display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        var x = pad * 2
        for (i, item) in items.enumerated() {
            let size = sizes[i]
            let frame = CGRect(x: x, y: pad * 2 + 34 + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            if i == selected {
                let highlight = CALayer()
                highlight.frame = frame.insetBy(dx: -pad, dy: -pad)
                highlight.backgroundColor = cgColor(Color(hex: "#999999ff")!)
                highlight.cornerRadius = 12
                root.addSublayer(highlight)
            }
            let preview = CALayer()
            preview.frame = frame
            preview.cornerRadius = 10
            preview.masksToBounds = true
            if let image = item.image {
                preview.contents = image
                preview.contentsGravity = .resizeAspect
            } else {
                preview.backgroundColor = CGColor(gray: 0.3, alpha: 1)
                if let icon = item.icon {
                    let l = CALayer()
                    l.contents = icon
                    l.contentsGravity = .resizeAspect
                    let side = min(64, size.width * 0.5, size.height * 0.5)
                    l.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
                    preview.addSublayer(l)
                }
            }
            root.addSublayer(preview)
            x += size.width + spacing
        }
        if items.indices.contains(selected) {
            let item = items[selected]
            label.string = item.title.isEmpty ? item.app : "\(item.title) — \(item.app)"
        }
        label.frame = CGRect(x: pad, y: pad, width: width - pad * 2, height: 20)
        root.addSublayer(label)
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }
}
