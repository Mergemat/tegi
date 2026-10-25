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
    @State private var search = ""
    @State private var recording: Recording?
    @State private var pending: Command?
    @State private var note: String?
    @State private var monitor: Any?

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
        Hero(height: 108) {
            HStack(spacing: 10) {
                KeyCap(text: "⌥")
                Text("+").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(tegiBlue)
                KeyCap(text: "H")
                Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(tegiBlue).padding(.horizontal, 6)
                Friend(radius: 6).frame(width: 34, height: 48)
                Mascot(ringWidth: 2.5, radius: 7).frame(width: 40, height: 48)
            }
        }
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
