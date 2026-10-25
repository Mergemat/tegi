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

/// The recent windows as a row of pictures; the picked one wears the focus ring, and the mascot peeks over the top.
private struct SwitcherView: View {
    static let pad = 26.0, spacing = 18.0, label = 44.0, peek = 30.0
    @ObservedObject var model: SwitcherModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        ZStack(alignment: .topLeading) {
            Mascot(ringWidth: 0, radius: 10).frame(width: 44, height: 52).offset(x: mascotX - 22, y: 0)
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: Self.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        thumb(item, size: model.sizes.indices.contains(i) ? model.sizes[i] : .zero, picked: i == model.selected)
                    }
                }
                if model.items.indices.contains(model.selected) { name(model.items[model.selected], t) }
            }
            .padding(Self.pad)
            .background {
                ZStack {
                    t.background
                    if t.night { Stars() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(t.night ? SwiftUI.Color.white.opacity(0.14) : t.edge))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
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
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = item.image {
                    Surface(image: image)
                } else {
                    ZStack {
                        Theme(scheme).chip
                        if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 56, height: 56) }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let icon = item.icon, item.image != nil {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .offset(x: -8, y: 8)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.ring, lineWidth: 3.5)
                .padding(-6)
                .shadow(color: model.ring.opacity(0.6), radius: 8)
                .opacity(picked ? 1 : 0)
        }
        .scaleEffect(picked ? 1 : 0.92)
        .opacity(picked ? 1 : 0.7)
    }

    private func name(_ item: RecentWindows.Item, _ t: Theme) -> some View {
        HStack(spacing: 8) {
            if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            Text(item.title.isEmpty ? item.app : item.title).foregroundStyle(t.text).lineLimit(1)
            if !item.title.isEmpty { Text(item.app).foregroundStyle(t.secondary).lineLimit(1).layoutPriority(1) }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(t.chip, in: Capsule())
        .frame(height: Self.label - 14)
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
