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

struct HotkeysPane: View {
    @EnvironmentObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""
    @State private var recording: Recording?
    @State private var pending: Command?
    @State private var note: String?
    @State private var monitor: Any?
    @State private var shiftMonitor: Any?
    @State private var shifted = false
    @State private var hovered: KeyCombo?

    struct Recording: Equatable {
        var command: Command
        var old: KeyCombo?
    }

    private var commands: [Command] {
        var all = Array(Command.simple.values) + model.config.binds.values + (pending.map { [$0] } ?? [])
        var seen: Set<String> = []
        all = all.filter { seen.insert($0.words.joined(separator: " ")).inserted }
        let query = search.lowercased()
        if !query.isEmpty {
            all = all.filter { c in
                title(of: c).lowercased().contains(query) || keys(c).contains { $0.symbol.lowercased().contains(query) || $0.description.contains(query) }
            }
        }
        return all.sorted { title(of: $0).localizedStandardCompare(title(of: $1)) == .orderedAscending }
    }

    private func keys(_ command: Command) -> [KeyCombo] {
        model.config.binds.filter { $0.value == command }.map(\.key).sorted { $0.description < $1.description }
    }

    var body: some View {
        let all = commands
        let mod = model.config.mod
        let layer = shifted ? Mods.shift.under(mod) : mod
        CardTitle("Your key")
        VStack(alignment: .leading, spacing: 8) {
            ModPicker(mod: mod) { model.setMod($0) }
            if mod.contains(.shift) {
                Text("Hyper is ⌃⌥⇧⌘ at once, usually Caps Lock through Karabiner-Elements or Hyperkey. It already holds Shift, so ⌥⇧ takes the window along.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme(scheme).secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 22)

        CardTitle(shifted ? "Taking the window along" : "On your key")
        Card {
            KeyboardMap(binds: model.config.binds, mods: layer, live: recording?.old, hover: { hovered = $0 },
                        tap: { combo in if let c = model.config.binds[combo] { record(c, replacing: combo) } },
                        remove: { combo in if let c = model.config.binds[combo] { model.bind(c, from: combo, to: nil) } })
                .padding(Space.card)
            caption(layer: layer)
                .padding(.horizontal, Space.card)
                .padding(.bottom, Space.card)
        }
        .onAppear {
            shiftMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                shifted = event.modifierFlags.contains(.shift)
                return event
            }
        }
        .onDisappear {
            if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
            shiftMonitor = nil
        }

        CardTitle("Every shortcut")
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
        ForEach(HotkeyGroup.allCases) { group in
            let rows = all.filter { HotkeyGroup($0) == group }
            if !rows.isEmpty {
                CardTitle(group.rawValue)
                Card {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, command in
                        Row(title: title(of: command), last: i == rows.count - 1) {
                            HStack(spacing: 6) {
                                ForEach(keys(command), id: \.description) { combo in
                                    KeyCap(text: combo.symbol, live: recording == Recording(command: command, old: combo))
                                        .onTapGesture { record(command, replacing: combo) }
                                        .contextMenu { Button("Remove shortcut") { model.bind(command, from: combo, to: nil) } }
                                        .help("Click to change; right-click to remove")
                                }
                                if recording == Recording(command: command, old: nil) {
                                    KeyCap(text: "", live: true).onTapGesture { stop() }
                                } else {
                                    Button { record(command, replacing: nil) } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                                        .buttonStyle(GummyButtonStyle())
                                        .help("Add a shortcut")
                                }
                            }
                        }
                    }
                }
            }
        }
        HStack {
            Button("Add a shortcut that opens an app…") {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.application]
                guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
                let command = Command.spawn(["open", "-b", id])
                pending = command
                record(command, replacing: nil)
            }
            .buttonStyle(GummyButtonStyle(prominent: true))
            Spacer()
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, 8)
        .onDisappear { stop() }
    }

    @ViewBuilder private func caption(layer: Mods) -> some View {
        let t = Theme(scheme)
        HStack(spacing: 8) {
            if let r = recording {
                Text("Press the new keys for \(title(of: r.command)). Esc cancels.")
            } else if let hovered, let command = model.config.binds[hovered] {
                KeyCap(text: hovered.symbol)
                Text(title(of: command)).foregroundStyle(t.text)
                Spacer()
                Text("Click to change").foregroundStyle(t.faint)
            } else {
                Text(shifted ? "Let go of ⇧ to see your key again." : "Hold ⇧ to see what takes the window along. Click a key to change it.")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(t.secondary)
        .frame(minHeight: 26)
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
            note = "\(combo.symbol) was \(title(of: taken)); now it's \(title(of: r.command))."
        } else {
            note = nil
        }
        model.bind(r.command, from: r.old, to: combo)
        pending = nil
    }
}
