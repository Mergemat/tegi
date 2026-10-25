import AppKit
import SwiftUI
import TegiCore

enum HotkeyGroup: String, CaseIterable, Identifiable {
    case basics = "Basics", focus = "Focus", move = "Move", workspaces = "Workspaces", displays = "Displays"
    case columns = "Columns", sizes = "Sizes", floating = "Floating", recent = "Recent windows", launch = "Open apps"
    var id: Self { self }

    init(_ command: Command) {
        let name = command.words.first ?? ""
        switch command {
        case .spawn, .spawnSh: self = .launch
        case .nextWindow, .previousWindow, .focusWindowPrevious: self = .recent
        case .showHotkeyOverlay, .toggleOverview, .openOverview, .closeOverview, .closeWindow, .quit, .showSettings: self = .basics
        default:
            if name.contains("workspace") { self = .workspaces }
            else if name.contains("monitor") { self = .displays }
            else if name.contains("floating") || name.contains("tiling") { self = .floating }
            else if name.hasPrefix("focus") { self = .focus }
            else if name.hasPrefix("move") || name.hasPrefix("swap") { self = .move }
            else if ["consume", "expel", "toggle-column-tabbed", "set-column-display", "center"].contains(where: name.hasPrefix) { self = .columns }
            else { self = .sizes }
        }
    }
}

func title(of command: Command) -> String {
    switch command {
    case .spawn(let args) where args.count == 3 && args[0] == "open" && args[1] == "-b":
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: args[2])
        return "Open " + (url?.deletingPathExtension().lastPathComponent ?? args[2])
    case .spawn(let args): return "Run " + args.joined(separator: " ")
    case .spawnSh(let line): return "Run " + line
    default: break
    }
    let words = command.words
    let names = [
        "show-hotkey-overlay": "Show hotkeys", "toggle-overview": "Overview", "show-settings": "Settings",
        "close-window": "Close window", "quit": "Quit tegi", "next-window": "Back to the last window",
        "previous-window": "Forward again", "next-window same-app": "Last window of this app",
        "previous-window same-app": "Forward again in this app", "focus-window-previous": "Last focused window",
    ]
    if let name = names[words.joined(separator: " ")] { return name }
    var s = (words.first ?? "").replacingOccurrences(of: "-", with: " ")
    s = s.prefix(1).uppercased() + s.dropFirst()
    return ([s] + words.dropFirst()).joined(separator: " ")
}

/// A direction you can go, and the same direction taking the window along.
private struct Pair {
    let title: String
    let go: Command
    let take: Command

    static let around: [Pair] = [
        Pair(title: "Column on the left", go: .focusColumnLeft, take: .moveColumnLeft),
        Pair(title: "Column on the right", go: .focusColumnRight, take: .moveColumnRight),
        Pair(title: "Window above", go: .focusWindowUp, take: .moveWindowUp),
        Pair(title: "Window below", go: .focusWindowDown, take: .moveWindowDown),
        Pair(title: "First column", go: .focusColumnFirst, take: .moveColumnToFirst),
        Pair(title: "Last column", go: .focusColumnLast, take: .moveColumnToLast),
        Pair(title: "Workspace above", go: .focusWorkspaceUp, take: .moveColumnToWorkspaceUp),
        Pair(title: "Workspace below", go: .focusWorkspaceDown, take: .moveColumnToWorkspaceDown),
        Pair(title: "Next display", go: .focusMonitor(.next), take: .moveColumnToMonitor(.next)),
        Pair(title: "Previous display", go: .focusMonitor(.previous), take: .moveColumnToMonitor(.previous)),
    ]

    static let numbered: [Pair] = (1...9).map {
        Pair(title: "Workspace \($0)", go: .focusWorkspace(.index($0)), take: .moveColumnToWorkspace(.index($0)))
    }

    static let all = around + numbered
}

struct HotkeysPane: View {
    @EnvironmentObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var recording: Recording?
    @State private var pending: Command?
    @State private var note: String?
    @State private var monitor: Any?
    @State private var numbers = false
    @State private var more: Set<HotkeyGroup> = []
    @State private var lit: Command?

    struct Recording: Equatable {
        var command: Command
        var old: KeyCombo?
    }

    private var everything: [Command] {
        var all = Array(Command.simple.values) + model.config.binds.values + (pending.map { [$0] } ?? [])
        var seen: Set<String> = []
        all = all.filter { seen.insert($0.words.joined(separator: " ")).inserted }
        return all.sorted { title(of: $0).localizedStandardCompare(title(of: $1)) == .orderedAscending }
    }

    private func keys(_ command: Command) -> [KeyCombo] {
        model.config.binds.filter { $0.value == command }.map(\.key).sorted { $0.description < $1.description }
    }

    var body: some View {
        let t = Theme(scheme)
        let mod = model.config.mod
        CardTitle("Your key")
        VStack(alignment: .leading, spacing: 8) {
            ModPicker(mod: mod) { model.setMod($0) }
            if mod == .hyper || mod == .hyperWithoutShift {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Hyper key includes ⇧").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
                        Text("Match Include Shift in Raycast, Tinycast or Hyperkey; it's off there unless you turned it on. Karabiner's usual Hyper includes it.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(t.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    GummyToggle(isOn: mod == .hyper) { model.setMod($0 ? .hyper : .hyperWithoutShift) }
                }
                .padding(.horizontal, Space.card).padding(.vertical, 12)
                .background(t.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.edge))
            } else {
                Text("Every shortcut on it moves when you pick another.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(t.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)

        GummyField(prompt: "Find a command or a key", text: $search)
            .padding(.horizontal, 16)
            .padding(.bottom, Space.between)
        if let note {
            Label(note, systemImage: "arrow.triangle.swap")
                .font(.system(size: 12, design: .rounded))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tegiBlue.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, Space.between)
        }

        let query = search.lowercased()
        if !query.isEmpty {
            let found = everything.filter { c in
                title(of: c).lowercased().contains(query) || keys(c).contains { $0.symbol(hyper: model.config.mod).lowercased().contains(query) || $0.description.contains(query) }
            }
            Card {
                if found.isEmpty { Row(title: "Nothing matches", last: true) { EmptyView() } }
                ForEach(Array(found.enumerated()), id: \.offset) { i, command in
                    Row(title: title(of: command), last: i == found.count - 1) { shortcuts(command) }
                }
            }
        } else {
            CardTitle("Getting around")
            Card {
                AroundMap(key: { keys($0).first }, lit: lit, mod: mod)
                    .padding(Space.card)
                Rectangle().fill(t.divider).frame(height: 1)
                pairHeader
                ForEach(Array(Pair.around.enumerated()), id: \.offset) { _, pair in pairRow(pair) }
                Button { withAnimation(.spring(duration: 0.3)) { numbers.toggle() } } label: {
                    Row(title: "Workspaces 1 to 9", last: !numbers) {
                        if !numbers { numberSummary }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(t.faint)
                            .rotationEffect(.degrees(numbers ? 90 : 0))
                            .frame(width: Self.chevron)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if numbers {
                    ForEach(Array(Pair.numbered.enumerated()), id: \.offset) { i, pair in pairRow(pair, last: i == 8) }
                }
            }

            let paired = Set(Pair.all.flatMap { [$0.go.words, $0.take.words] })
            ForEach(HotkeyGroup.allCases) { group in
                let rows = everything.filter { HotkeyGroup($0) == group && !paired.contains($0.words) }
                let bound = rows.filter { !keys($0).isEmpty || $0 == pending }
                let rest = rows.filter { keys($0).isEmpty && $0 != pending }
                let open = more.contains(group)
                if !bound.isEmpty || group == .launch {
                    CardTitle(group.rawValue)
                    Card {
                        let shown = bound + (open ? rest : [])
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, command in
                            Row(title: title(of: command), last: i == shown.count - 1 && rest.isEmpty && group != .launch) { shortcuts(command) }
                        }
                        if group == .launch {
                            Row(title: "Open an app", last: true) {
                                Button("Choose…") { chooseApp() }.buttonStyle(GummyButtonStyle())
                            }
                        } else if !rest.isEmpty {
                            Button {
                                withAnimation(.spring(duration: 0.3)) { if open { more.remove(group) } else { more.insert(group) } }
                            } label: {
                                HStack {
                                    Text(open ? "Fewer" : "\(rest.count) more without a shortcut")
                                    Spacer()
                                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                                }
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(t.faint)
                                .padding(.horizontal, Space.card)
                                .frame(minHeight: 40)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        Spacer(minLength: 0).onDisappear { stop() }
    }

    private static let column: CGFloat = 132
    // Every pair row leaves room for the numbers row's chevron, so the columns line up.
    private static let chevron: CGFloat = 12

    private var pairHeader: some View {
        // The same spacing as a row's controls, so the headers sit over their columns.
        HStack(spacing: 16) {
            Spacer()
            Text("Go").frame(width: Self.column, alignment: .leading)
            Text("Take the window").frame(width: Self.column, alignment: .leading)
            SwiftUI.Color.clear.frame(width: Self.chevron, height: 1)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(Theme(scheme).faint)
        .padding(.horizontal, Space.card)
        .padding(.top, 12)
    }

    private func pairRow(_ pair: Pair, last: Bool = false) -> some View {
        Row(title: pair.title, last: last) {
            shortcuts(pair.go).frame(width: Self.column, alignment: .leading)
            shortcuts(pair.take).frame(width: Self.column, alignment: .leading)
            SwiftUI.Color.clear.frame(width: Self.chevron, height: 1)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(duration: 0.25)) { lit = inside ? pair.go : (lit == pair.go ? nil : lit) }
        }
    }

    // The nine number keys usually follow one pattern; when they do, one row says so.
    @ViewBuilder private var numberSummary: some View {
        let go = Pair.numbered.map { keys($0.go) }, take = Pair.numbered.map { keys($0.take) }
        summary(go).frame(width: Self.column, alignment: .leading)
        summary(take).frame(width: Self.column, alignment: .leading)
    }

    @ViewBuilder private func summary(_ keys: [[KeyCombo]]) -> some View {
        let singles = keys.compactMap { $0.count == 1 ? $0[0] : nil }
        if singles.count == 9, Set(singles.map(\.mods)).count == 1, singles.enumerated().allSatisfy({ $1.key == "\($0 + 1)" }) {
            KeyCap(text: String(singles[0].symbol(hyper: model.config.mod).dropLast()) + "1–9")
        } else {
            Text("\(keys.filter { !$0.isEmpty }.count) of 9 set").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme(scheme).faint)
        }
    }

    private func shortcuts(_ command: Command) -> some View {
        HStack(spacing: 6) {
            ForEach(keys(command), id: \.description) { combo in
                KeyCap(text: combo.symbol(hyper: model.config.mod), live: recording == Recording(command: command, old: combo))
                    .onTapGesture { record(command, replacing: combo) }
                    .contextMenu {
                        Button("Add another shortcut") { record(command, replacing: nil) }
                        Button("Remove shortcut") { model.bind(command, from: combo, to: nil) }
                    }
                    .help("Click to change; right-click for more")
            }
            if recording == Recording(command: command, old: nil) {
                KeyCap(text: "", live: true).onTapGesture { stop() }
            } else if keys(command).isEmpty {
                Button { record(command, replacing: nil) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(GummyButtonStyle())
                    .help("Add a shortcut")
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let command = Command.spawn(["open", "-b", id])
        pending = command
        record(command, replacing: nil)
    }

    private func record(_ command: Command, replacing old: KeyCombo?) {
        stop()
        recording = Recording(command: command, old: old)
        model.onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if monitor != nil { model.onRecording(false) }
        monitor = nil
        recording = nil
    }

    private func handle(_ event: NSEvent) {
        guard let r = recording else { return }
        defer {
            stop()
            if pending == r.command && keys(r.command).isEmpty { pending = nil }
        }
        let flags = event.modifierFlags
        var mods: Mods = []
        if flags.contains(.command) { mods.insert(.cmd) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.shift) { mods.insert(.shift) }
        switch event.keyCode {
        case 53 where mods.isEmpty: return
        case 51 where mods.isEmpty:
            if let old = r.old { model.bind(r.command, from: old, to: nil) }
            return
        default: break
        }
        let functionKey = (96...122).contains(Int(event.keyCode))
        guard let combo = KeyCombo(keyCode: UInt32(event.keyCode), mods: mods), !mods.isEmpty || functionKey else {
            note = "Shortcuts need a modifier like ⌥, unless they're a function key."
            return
        }
        if let taken = model.config.binds[combo], taken != r.command {
            note = "\(combo.symbol(hyper: model.config.mod)) was \(title(of: taken)); now it's \(title(of: r.command))."
        } else {
            note = nil
        }
        model.bind(r.command, from: r.old, to: combo)
        pending = nil
    }
}

/// The focused window in its strip, with every place the table can take you and the key that gets there.
private struct AroundMap: View {
    @Environment(\.colorScheme) private var scheme
    let key: (Command) -> KeyCombo?
    let lit: Command?
    let mod: Mods

    var body: some View {
        let t = Theme(scheme)
        VStack(spacing: 12) {
            VStack(spacing: 8) {
            peek(.focusWorkspaceUp)
            HStack(spacing: 8) {
                place(.focusColumnFirst, width: 42)
                dots
                place(.focusColumnLeft, width: 48)
                VStack(spacing: 6) {
                    place(.focusWindowUp, width: 60, height: 34)
                    Mascot(ringWidth: 2.5, radius: 9).frame(width: 60, height: 62)
                    place(.focusWindowDown, width: 60, height: 34)
                }
                place(.focusColumnRight, width: 48)
                dots
                place(.focusColumnLast, width: 42)
            }
            .frame(height: 146)
            .padding(10)
            .background(t.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            peek(.focusWorkspaceDown)
            }
            // As wide as the strip, so the workspaces above and below line up with it.
            .fixedSize(horizontal: true, vertical: false)
            SceneCaption("\(added) to any of these and the window comes along")
        }
        .frame(maxWidth: .infinity)
    }

    // A key without Shift adds it; one that already holds Shift moves to ⌥⇧.
    private var added: String {
        let take = Mods.shift.under(mod)
        return take.isSuperset(of: mod) ? "Add ⇧" : "Use \(take.symbol)"
    }

    private var dots: some View {
        Text("···").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme(scheme).faint)
    }

    private func place(_ command: Command, width: CGFloat, height: CGFloat? = nil) -> some View {
        let on = lit == command
        return ZStack {
            Friend(radius: 8, face: (height ?? 99) > 40)
                .opacity(lit == nil || on ? 1 : 0.45)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? tegiBlue : .clear, lineWidth: 2.5))
                .shadow(color: on ? tegiBlue.opacity(0.6) : .clear, radius: 8)
            if let combo = key(command) {
                KeyCap(text: combo.symbol(hyper: mod)).scaleEffect(on ? 1.1 : 1)
                    .frame(maxHeight: .infinity, alignment: height == nil ? .bottom : .center)
                    .padding(.bottom, height == nil ? 8 : 0)
            }
        }
        .frame(width: width, height: height)
    }

    private func peek(_ command: Command) -> some View {
        let t = Theme(scheme), on = lit == command
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(t.chip)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? tegiBlue : .clear, lineWidth: 2))
                .shadow(color: on ? tegiBlue.opacity(0.5) : .clear, radius: 8)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            if let combo = key(command) {
                HStack(spacing: 6) {
                    KeyCap(text: combo.symbol(hyper: mod))
                    Text(command == .focusWorkspaceUp ? "workspace above" : "workspace below")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(t.secondary)
                }
                .scaleEffect(on ? 1.06 : 1)
            }
        }
    }
}

extension Mods {
    var symbol: String { String(KeyCombo(keyCode: 0, mods: self)!.symbol.dropLast()) }
}

/// Your key: one choice that every mod+… shortcut follows.
struct ModPicker: View {
    @Environment(\.colorScheme) private var scheme
    let mod: Mods
    let pick: (Mods) -> Void

    private static let options: [(Mods, String)] = [(.alt, "Option"), ([.ctrl, .alt], "Control Option"), ([.cmd, .alt], "Command Option"),
                                                     (.hyperWithoutShift, "Hyper")]

    // Either kind of Hyper lights the Hyper tile; the toggle below it says which.
    private func picked(_ option: Mods) -> Bool { option == mod || (option == .hyperWithoutShift && mod == .hyper) }

    var body: some View {
        let t = Theme(scheme)
        let options = Self.options.contains { picked($0.0) } ? Self.options : Self.options + [(mod, "Yours")]
        HStack(spacing: 8) {
            ForEach(options, id: \.0.rawValue) { option, name in
                let on = picked(option)
                VStack(spacing: 3) {
                    Text(option == .hyperWithoutShift ? "✦" : option.symbol).font(.system(size: 19, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
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
