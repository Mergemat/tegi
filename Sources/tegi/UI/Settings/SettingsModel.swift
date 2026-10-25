import AppKit
import TegiCore

// The config file is the only state: every change is written there and comes back through tegi's reload.
final class SettingsModel: ObservableObject {
    @Published private(set) var config = Config.builtIn { didSet { keymap = Keymap(config) } }
    private(set) var keymap = Keymap(Config.builtIn)
    @Published private(set) var problem: String?
    /// A change still being dragged: previews show it before it's written.
    @Published private(set) var live: Config?
    /// Counts saves, so the mascot can react to each one.
    @Published private(set) var saves = 0
    private var pending: DispatchWorkItem?
    @Published private var text = ""
    let url: URL
    var onRecording: (Bool) -> Void = { _ in }
    var onPermissions: () -> Void = {}
    var onCheatSheet: () -> Void = {}

    init(url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        let read = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Unchanged, it would only redraw every page for nothing.
        guard read != text else { return }
        text = read
        do {
            config = try Config.parse(read)
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    var shown: Config { live ?? config }

    func preview(_ change: (inout Config) -> Void) {
        var c = live ?? config
        change(&c)
        live = c
    }

    func endPreview() { live = nil }

    /// Shows a change now and writes it once it has stopped changing, for the color panel's stream of picks.
    func setSoon(_ key: [String], _ args: [String]?, preview change: (inout Config) -> Void) {
        preview(change)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.set(key, args)
            self?.endPreview()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func isSet(_ key: [String]) -> Bool { ConfigEditor.has(key, in: text) }

    func set(_ key: [String], _ args: [String]?) { write(ConfigEditor.set(key, to: args, in: text)) }

    func setList(_ name: String, _ lines: [[String]]) { write(ConfigEditor.setList(name, to: lines, in: text)) }

    func setMod(_ mod: Mods) { write(ConfigEditor.setMod(mod, in: text)) }

    func bind(_ command: Command, from old: KeyCombo?, to new: KeyCombo?) {
        write(ConfigEditor.bind(command, from: old, to: new, in: text))
    }

    private func write(_ new: String) {
        guard new != text else { return }
        do {
            let parsed = try Config.parse(new)
            try new.write(to: url, atomically: true, encoding: .utf8)
            text = new
            config = parsed
            problem = nil
            saves += 1
        } catch {
            problem = "\(error)"
        }
    }
}

func number(_ v: Double) -> String { String(format: "%.5g", v) }
