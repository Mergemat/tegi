import AppKit
import SwiftUI
import TegiCore

extension HotkeyGroup {
    var tint: SwiftUI.Color {
        switch self {
        case .basics: SwiftUI.Color(hex: 0xff6b81)
        case .focus: SwiftUI.Color(hex: 0x5aa8ff)
        case .move: SwiftUI.Color(hex: 0x4f7dff)
        case .workspaces: SwiftUI.Color(hex: 0x9b7bff)
        case .displays: SwiftUI.Color(hex: 0x2fc4d8)
        case .columns: SwiftUI.Color(hex: 0x3fcf8e)
        case .sizes: SwiftUI.Color(hex: 0xffa94d)
        case .floating: SwiftUI.Color(hex: 0xff7aa8)
        case .recent: SwiftUI.Color(hex: 0x8a90a8)
        case .launch: SwiftUI.Color(hex: 0xf5b83d)
        }
    }
}

/// What a key shows on the keyboard: the app it opens, a number, or a symbol for what it does.
enum Glyph {
    case icon(NSImage), text(String), symbol(String)

    init(_ command: Command) {
        if case .spawn(let a) = command, a.count == 3, a[0] == "open", a[1] == "-b",
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a[2]) {
            self = .icon(NSWorkspace.shared.icon(forFile: url.path))
            return
        }
        let words = command.words
        if let n = words.last, Int(n) != nil, words.count == 2 {
            self = .text(n)
            return
        }
        let name = words.first ?? ""
        let named = [
            "toggle-overview": "square.grid.2x2.fill", "close-window": "xmark", "show-hotkey-overlay": "questionmark",
            "show-settings": "gearshape.fill", "quit": "power", "toggle-column-tabbed-display": "rectangle.stack.fill",
            "consume-window-into-column": "arrow.down.to.line", "expel-window-from-column": "arrow.up.to.line",
            "maximize-column": "arrow.left.and.right", "fullscreen-window": "arrow.up.left.and.arrow.down.right",
            "expand-column-to-available-width": "arrow.left.and.line.vertical.and.arrow.right",
            "center-column": "align.horizontal.center.fill", "center-visible-columns": "align.horizontal.center",
            "switch-preset-column-width": "rectangle.split.3x1.fill", "switch-preset-column-width-back": "rectangle.split.3x1",
            "toggle-window-floating": "macwindow.on.rectangle", "switch-focus-between-floating-and-tiling": "rectangle.2.swap",
            "next-window": "arrow.uturn.backward", "previous-window": "arrow.uturn.forward",
            "focus-monitor-next": "display", "focus-monitor-previous": "display",
            "move-column-to-monitor-next": "arrow.right.to.line", "move-column-to-monitor-previous": "arrow.left.to.line",
        ]
        if let symbol = named[name] {
            self = .symbol(symbol)
        } else if let arg = words.dropFirst().first, arg.hasPrefix("+") || arg.hasPrefix("-") {
            self = .symbol(arg.hasPrefix("+") ? "plus" : "minus")
        } else if let direction = ["left", "right", "up", "down"].first(where: { name.hasSuffix($0) }) {
            self = .symbol("arrow.\(direction)")
        } else if name.hasSuffix("first") || name.hasSuffix("last") {
            self = .symbol(name.hasSuffix("first") ? "arrow.left.to.line" : "arrow.right.to.line")
        } else {
            self = .symbol("circle.fill")
        }
    }
}

/// The keyboard, coloured by what each key does on your key; holding Shift shows the layer that takes the window along.
struct KeyboardMap: View {
    @Environment(\.colorScheme) private var scheme
    let binds: [KeyCombo: Command]
    let mods: Mods
    var live: KeyCombo?
    let hover: (KeyCombo?) -> Void
    let tap: (KeyCombo) -> Void
    let remove: (KeyCombo) -> Void

    private static let rows: [(indent: CGFloat, keys: [String])] = [
        (0, ["grave", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal"]),
        (0.3, ["tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "bracketleft", "bracketright"]),
        (0.6, ["a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "quote"]),
        (1.1, ["z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash"]),
    ]
    private let gap: CGFloat = 5

    var body: some View {
        KeyRows(gap: gap) {
            GeometryReader { geo in
                let size = KeyRows.key(width: geo.size.width, gap: gap)
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: gap) {
                            ForEach(row.keys, id: \.self) { name in key(name, size: size) }
                        }
                        .padding(.leading, row.indent * size)
                    }
                }
            }
        }
    }

    @ViewBuilder private func key(_ name: String, size: CGFloat) -> some View {
        let t = Theme(scheme)
        let combo = KeyCombo("\(mods.text)+\(name)")
        let command = combo.flatMap { binds[$0] }
        let label = KeyCombo(name)?.symbol ?? name
        let isLive = combo != nil && combo == live
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(isLive ? AnyShapeStyle(gummyBlue)
                      : command.map { c in AnyShapeStyle(LinearGradient(colors: [HotkeyGroup(c).tint.opacity(0.85), HotkeyGroup(c).tint],
                                                                        startPoint: .top, endPoint: .bottom)) }
                      ?? AnyShapeStyle(t.chip))
                .shadow(color: .black.opacity(command == nil ? 0 : 0.25), radius: 0, y: 2)
            Text(label)
                .font(.system(size: max(8, size * 0.22), weight: .bold, design: .rounded))
                .foregroundStyle(command == nil ? t.faint : .white.opacity(0.75))
                .padding(.leading, size * 0.13).padding(.top, size * 0.08)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: command == nil ? .center : .topLeading)
            if let command { glyph(Glyph(command), size: size).frame(maxWidth: .infinity, maxHeight: .infinity).offset(y: size * 0.06) }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onHover { inside in hover(inside ? combo : nil) }
        .onTapGesture { if let combo, command != nil { tap(combo) } }
        .contextMenu {
            if let combo, command != nil { Button("Remove shortcut") { remove(combo) } }
        }
    }

    @ViewBuilder private func glyph(_ g: Glyph, size: CGFloat) -> some View {
        switch g {
        case .icon(let image): Image(nsImage: image).resizable().frame(width: size * 0.5, height: size * 0.5)
        case .text(let s): Text(s).font(.system(size: size * 0.36, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        case .symbol(let s): Image(systemName: s).font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white)
        }
    }
}

/// Takes the width it's offered and is as tall as four rows of keys that fit it.
private struct KeyRows: Layout {
    let gap: CGFloat

    // The widest rows hold 13 keys and a 0.3-key indent.
    static func key(width: CGFloat, gap: CGFloat) -> CGFloat { (width - 12 * gap) / 13.3 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: 4 * Self.key(width: width, gap: gap) + 3 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}

/// Your key: one choice that every mod+… shortcut follows.
struct ModPicker: View {
    @Environment(\.colorScheme) private var scheme
    let mod: Mods
    let pick: (Mods) -> Void

    private static let options: [(Mods, String)] = [(.alt, "Option"), ([.ctrl, .alt], "Control Option"), ([.cmd, .alt], "Command Option"), (.hyper, "Hyper")]

    var body: some View {
        let t = Theme(scheme)
        let options = Self.options.contains { $0.0 == mod } ? Self.options : Self.options + [(mod, "Yours")]
        HStack(spacing: 8) {
            ForEach(options, id: \.0.rawValue) { option, name in
                let on = option == mod
                VStack(spacing: 3) {
                    Text(String(KeyCombo(keyCode: 0, mods: option)!.symbol.dropLast()))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(t.text)
                    Text(name).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(t.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(on ? tegiBlue.opacity(t.night ? 0.16 : 0.12) : t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? tegiBlue : t.edge, lineWidth: on ? 1.5 : 1))
                .contentShape(Rectangle())
                .onTapGesture { if !on { pick(option) } }
            }
        }
    }
}
