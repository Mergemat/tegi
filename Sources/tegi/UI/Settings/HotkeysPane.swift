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

    static let columns: [Pair] = [
        Pair(title: "On the left", go: .focusColumnLeft, take: .moveColumnLeft),
        Pair(title: "On the right", go: .focusColumnRight, take: .moveColumnRight),
        Pair(title: "First", go: .focusColumnFirst, take: .moveColumnToFirst),
        Pair(title: "Last", go: .focusColumnLast, take: .moveColumnToLast),
    ]
    static let stack: [Pair] = [
        Pair(title: "Above", go: .focusWindowUp, take: .moveWindowUp),
        Pair(title: "Below", go: .focusWindowDown, take: .moveWindowDown),
    ]
    static let workspaces: [Pair] = [
        Pair(title: "Above", go: .focusWorkspaceUp, take: .moveColumnToWorkspaceUp),
        Pair(title: "Below", go: .focusWorkspaceDown, take: .moveColumnToWorkspaceDown),
    ]
    static let displays: [Pair] = [
        Pair(title: "Next", go: .focusMonitor(.next), take: .moveColumnToMonitor(.next)),
        Pair(title: "Previous", go: .focusMonitor(.previous), take: .moveColumnToMonitor(.previous)),
    ]

    static let numbered: [Pair] = (1...9).map {
        Pair(title: "Workspace \($0)", go: .focusWorkspace(.index($0)), take: .moveColumnToWorkspace(.index($0)))
    }

    static let all = columns + stack + workspaces + displays + numbered
    static let paired = Set(all.flatMap { [$0.go.words, $0.take.words] })
}

struct HotkeysPane: View {
    @EnvironmentObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    // Off while another page is showing; this page stays built behind it.
    @Environment(\.isEnabled) private var showing
    @State private var search = ""
    @State private var recording: Recording?
    @State private var pending: Command?
    @State private var note: String?
    @State private var monitor: Any?
    @State private var numbers = false
    @State private var more: Set<Topic> = []

    struct Recording: Equatable {
        var command: Command
        var old: KeyCombo?
    }

    private var everything: [Command] {
        let all = model.keymap.commands
        guard let pending, model.keymap.keys(pending).isEmpty else { return all }
        return [pending] + all.filter { $0 != pending }
    }

    private func keys(_ command: Command) -> [KeyCombo] { model.keymap.keys(command) }

    private func title(of command: Command) -> String { model.keymap.title(command) }

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
            ForEach(Topic.allCases) { topic in section(topic) }
        }
        Spacer(minLength: 0)
            .onDisappear { stop() }
            .onChange(of: showing) { if !showing { stop() } }
    }

    private static let column: CGFloat = 132
    // Every pair row leaves room for the numbers row's chevron, so the columns line up.
    private static let chevron: CGFloat = 12

    @ViewBuilder private func section(_ topic: Topic) -> some View {
        let t = Theme(scheme)
        let pairs = topic.pairs
        let rows = everything.filter { Topic($0) == topic && !Pair.paired.contains($0.words) }
        let bound = rows.filter { !keys($0).isEmpty || $0 == pending }
        let rest = rows.filter { keys($0).isEmpty && $0 != pending }
        let open = more.contains(topic)
        let shown = bound + (open ? rest : [])
        CardTitle(topic.title)
        Card {
            TopicArt(topic: topic).frame(height: 64).frame(maxWidth: .infinity).padding(.vertical, 14)
            Rectangle().fill(t.divider).frame(height: 1)
            if !pairs.isEmpty {
                pairHeader
                ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                    pairRow(pair, last: i == pairs.count - 1 && topic != .workspaces && shown.isEmpty && rest.isEmpty)
                }
            }
            if topic == .workspaces {
                Button { withAnimation(.spring(duration: 0.3)) { numbers.toggle() } } label: {
                    Row(title: "1 to 9", last: !numbers && shown.isEmpty && rest.isEmpty) {
                        if !numbers { numberSummary }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(t.faint)
                            .rotationEffect(.degrees(numbers ? 90 : 0))
                            .frame(width: Self.chevron)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if numbers {
                    ForEach(Array(Pair.numbered.enumerated()), id: \.offset) { i, pair in
                        pairRow(pair, last: i == 8 && shown.isEmpty && rest.isEmpty)
                    }
                }
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, command in
                Row(title: title(of: command), last: i == shown.count - 1 && rest.isEmpty && topic != .launch) { shortcuts(command) }
            }
            if topic == .launch {
                Row(title: "Open an app", last: true) {
                    Button("Choose…") { chooseApp() }.buttonStyle(GummyButtonStyle())
                }
            } else if !rest.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.3)) { if open { more.remove(topic) } else { more.insert(topic) } }
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

/// The hotkeys page's sections, in the order people reach for them.
enum Topic: CaseIterable, Identifiable {
    case basics, columns, stack, workspaces, displays, arranging, sizes, floating, recent, launch
    var id: Self { self }

    init(_ command: Command) {
        let name = command.words.first ?? ""
        switch HotkeyGroup(command) {
        case .basics: self = .basics
        case .focus, .move: self = name.contains("window") && !name.contains("column") && !name.contains("swap") ? .stack : .columns
        case .workspaces: self = .workspaces
        case .displays: self = .displays
        case .columns: self = .arranging
        case .sizes: self = .sizes
        case .floating: self = .floating
        case .recent: self = .recent
        case .launch: self = .launch
        }
    }

    var title: String {
        switch self {
        case .basics: "Basics"
        case .columns: "Columns"
        case .stack: "Windows in a column"
        case .workspaces: "Workspaces"
        case .displays: "Displays"
        case .arranging: "Arranging columns"
        case .sizes: "Sizes"
        case .floating: "Floating"
        case .recent: "Recent windows"
        case .launch: "Open apps"
        }
    }

    fileprivate var pairs: [Pair] {
        switch self {
        case .columns: Pair.columns
        case .stack: Pair.stack
        case .workspaces: Pair.workspaces
        case .displays: Pair.displays
        default: []
        }
    }
}

/// A small picture of what a section's shortcuts do.
private struct TopicArt: View {
    @Environment(\.colorScheme) private var scheme
    let topic: Topic

    var body: some View {
        let t = Theme(scheme)
        switch topic {
        case .basics:
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 4) {
                        Friend(radius: 4, face: false).frame(width: 30, height: 20)
                        if i == 1 { Mascot(ringWidth: 1.5, radius: 4).frame(width: 30, height: 20) } else { Friend(radius: 4, face: false).frame(width: 30, height: 20) }
                    }
                }
            }
            .padding(8)
            .background(t.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .columns:
            HStack(spacing: 8) {
                Friend(radius: 6).frame(width: 30, height: 56).opacity(0.6)
                arrow("arrow.left")
                Mascot(ringWidth: 2, radius: 7).frame(width: 44, height: 56)
                arrow("arrow.right")
                Friend(radius: 6).frame(width: 30, height: 56).opacity(0.6)
            }
        case .stack:
            HStack(spacing: 10) {
                VStack(spacing: 4) {
                    Friend(radius: 5, face: false).frame(width: 48, height: 14).opacity(0.6)
                    Mascot(ringWidth: 2, radius: 6).frame(width: 48, height: 30)
                    Friend(radius: 5, face: false).frame(width: 48, height: 14).opacity(0.6)
                }
                arrow("arrow.up.arrow.down")
            }
        case .workspaces:
            HStack(spacing: 10) {
                VStack(spacing: 5) {
                    bar(false)
                    bar(true)
                    bar(false)
                }
                arrow("arrow.up.arrow.down")
            }
        case .displays:
            HStack(spacing: 10) {
                display(true)
                arrow("arrow.right")
                display(false)
            }
        case .arranging:
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Mascot(ringWidth: 2, radius: 6).frame(width: 30, height: 52)
                    Friend(radius: 6).frame(width: 30, height: 52)
                }
                arrow("arrow.right")
                VStack(spacing: 4) {
                    Mascot(ringWidth: 2, radius: 6).frame(width: 40, height: 24)
                    Friend(radius: 6, face: false).frame(width: 40, height: 24)
                }
            }
        case .sizes:
            HStack(spacing: 6) {
                arrow("arrow.left")
                Mascot(ringWidth: 2, radius: 7).frame(width: 70, height: 56)
                arrow("arrow.right")
            }
        case .floating:
            ZStack {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in Friend(radius: 5, face: false).frame(width: 34, height: 50).opacity(0.5) }
                }
                Mascot(ringWidth: 2, radius: 6).frame(width: 46, height: 36)
                    .offset(x: 14, y: -6)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 4)
            }
        case .recent:
            HStack(spacing: 10) {
                ZStack {
                    Friend(radius: 6, face: false).frame(width: 40, height: 48).offset(x: -12, y: -4).opacity(0.5)
                    Friend(radius: 6, face: false).frame(width: 40, height: 48).offset(x: -6, y: -2).opacity(0.75)
                    Mascot(ringWidth: 2, radius: 6).frame(width: 40, height: 48)
                }
                arrow("arrow.uturn.backward")
            }
        case .launch:
            HStack(spacing: 10) {
                Image(systemName: "app.dashed").font(.system(size: 28, weight: .semibold)).foregroundStyle(t.faint)
                arrow("arrow.right")
                Mascot(ringWidth: 2, radius: 7).frame(width: 44, height: 56)
            }
        }
    }

    private func arrow(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tegiBlue)
    }

    private func bar(_ current: Bool) -> some View {
        HStack(spacing: 3) {
            Friend(radius: 3, face: false).frame(width: 18)
            if current { Mascot(ringWidth: 1.5, radius: 3).frame(width: 18) } else { Friend(radius: 3, face: false).frame(width: 18) }
            Friend(radius: 3, face: false).frame(width: 18)
        }
        .padding(3)
        .frame(height: 18)
        .background(Theme(scheme).chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(current ? 1 : 0.55)
    }

    private func display(_ current: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme(scheme).chip)
                if current { Mascot(ringWidth: 1.5, radius: 4).frame(width: 22, height: 26) } else { Friend(radius: 4).frame(width: 22, height: 26).opacity(0.6) }
            }
            .frame(width: 64, height: 42)
            Capsule().fill(Theme(scheme).chip).frame(width: 24, height: 4)
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

/// The keymap as the Hotkeys page reads it: every command in name order, and each one's keys, worked out once per config.
struct Keymap {
    let commands: [Command]
    private let keys: [String: [KeyCombo]]
    private let titles: [String: String]

    init(_ config: Config) {
        func id(_ c: Command) -> String { c.words.joined(separator: " ") }
        var seen: Set<String> = [], titles: [String: String] = [:]
        let all = (Array(Command.simple.values) + config.binds.values).filter { seen.insert(id($0)).inserted }
        let named = all.map { (command: $0, title: tegi.title(of: $0)) }
        for n in named { titles[id(n.command)] = n.title }
        commands = named.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map(\.command)
        keys = Dictionary(grouping: config.binds, by: { id($0.value) }).mapValues { $0.map(\.key).sorted { $0.description < $1.description } }
        self.titles = titles
    }

    func keys(_ command: Command) -> [KeyCombo] { keys[command.words.joined(separator: " ")] ?? [] }
    func title(_ command: Command) -> String { titles[command.words.joined(separator: " ")] ?? tegi.title(of: command) }
}
