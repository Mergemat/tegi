import AppKit
import SwiftUI
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
    private var session: (items: [Item], selected: Int, modifiers: NSEvent.ModifierFlags, ring: TegiCore.Color)?
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

    func open(_ items: [Item], forward: Bool, ring: TegiCore.Color) {
        guard items.count > 1 else { return }
        let held = NSEvent.modifierFlags.intersection([.option, .command, .control, .shift])
        guard !held.isEmpty else {
            let id = items[forward ? 1 : items.count - 1].id
            commit(id)
            return onCommit(id)
        }
        session = (items, forward ? 1 : items.count - 1, held, ring)
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in self?.modifiersChanged() }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .flagsChanged { modifiersChanged() } else { key(e.keyCode) }
            return nil
        }
        monitors = [flags, local].compactMap { $0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let s = session else { return }
            let panel = SwitcherPanel(ring: s.ring)
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
    private let model: SwitcherModel

    init(ring: TegiCore.Color) {
        model = SwitcherModel(ring: SwiftUI.Color(ring))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: SwitcherView(model: model))
    }

    func show(_ items: [RecentWindows.Item], selected: Int) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxHeight = min(420, visible.height * 0.45)
        var sizes = items.map { item -> CGSize in
            let scale = min(0.5, maxHeight / max(item.size.height, 1))
            return CGSize(width: item.size.width * scale, height: item.size.height * scale)
        }
        let chrome = SwitcherView.pad * 2 + SwitcherView.spacing * Double(max(items.count - 1, 0))
        let fit = min(1, (visible.width * 0.92 - chrome) / max(sizes.reduce(0) { $0 + $1.width }, 1))
        sizes = sizes.map { CGSize(width: ($0.width * fit).rounded(), height: ($0.height * fit).rounded()) }
        let width = sizes.reduce(0) { $0 + $1.width } + chrome
        let height = (sizes.map(\.height).max() ?? 0) + SwitcherView.pad * 2 + SwitcherView.label + SwitcherView.peek
        setFrame(CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height), display: false)
        let first = model.items.isEmpty
        model.items = items
        model.sizes = sizes
        if first {
            model.selected = selected
        } else {
            withAnimation(.spring(duration: 0.28, bounce: 0.3)) { model.selected = selected }
        }
        if !isVisible { orderFrontRegardless() }
    }
}

private final class SwitcherModel: ObservableObject {
    let ring: SwiftUI.Color
    @Published var items: [RecentWindows.Item] = []
    @Published var sizes: [CGSize] = []
    @Published var selected = 0

    init(ring: SwiftUI.Color) { self.ring = ring }
}

/// The recent windows on a plain frosted strip: the picked one wears the focus ring, with the mascot peeking over it.
private struct SwitcherView: View {
    static let pad = 14.0, spacing = 12.0, label = 26.0, peek = 18.0
    @ObservedObject var model: SwitcherModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Mascot(ringWidth: 0, radius: 7).frame(width: 28, height: 32).offset(x: mascotX - 14, y: 0)
            VStack(spacing: 8) {
                HStack(spacing: Self.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        thumb(item, size: model.sizes.indices.contains(i) ? model.sizes[i] : .zero, picked: i == model.selected)
                    }
                }
                if model.items.indices.contains(model.selected) {
                    let item = model.items[model.selected]
                    Text(item.title.isEmpty ? item.app : item.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Self.label - 8)
                }
            }
            .padding(Self.pad)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.top, Self.peek)
        }
    }

    // Above the middle of the picked window, so the mascot moves along as you step.
    private var mascotX: Double {
        let before = model.sizes.prefix(model.selected).reduce(0) { $0 + $1.width + Self.spacing }
        let width = model.sizes.indices.contains(model.selected) ? model.sizes[model.selected].width : 0
        return Self.pad + before + width / 2
    }

    private func thumb(_ item: RecentWindows.Item, size: CGSize, picked: Bool) -> some View {
        Group {
            if let image = item.image {
                Surface(image: image)
            } else {
                ZStack {
                    SwiftUI.Color.primary.opacity(0.06)
                    if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48) }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.ring, lineWidth: 3)
                .padding(-5)
                .opacity(picked ? 1 : 0)
        }
        .scaleEffect(picked ? 1 : 0.94)
    }
}

/// A window picture straight from its surface: no CGImage copy, so stepping through stays instant.
private struct Surface: NSViewRepresentable {
    let image: IOSurface

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.layer?.contents as AnyObject? !== image { view.layer?.contents = image }
    }
}
