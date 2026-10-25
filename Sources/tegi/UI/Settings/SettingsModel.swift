import AppKit
import TegiCore

// The config file is the only state: every change is written there and comes back through tegi's reload.
final class SettingsModel: ObservableObject {
    @Published private(set) var config = Config.builtIn
    @Published private(set) var problem: String?
    @Published private var text = ""
    let url: URL
    var onRecording: (Bool) -> Void = { _ in }

    init(url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        let read = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = read
        do {
            config = try Config.parse(read)
            problem = nil
        } catch {
            problem = "\(error)"
        }
    }

    func isSet(_ key: [String]) -> Bool { ConfigEditor.has(key, in: text) }

    func set(_ key: [String], _ args: [String]?) { write(ConfigEditor.set(key, to: args, in: text)) }

    func setList(_ name: String, _ lines: [[String]]) { write(ConfigEditor.setList(name, to: lines, in: text)) }

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
        } catch {
            problem = "\(error)"
        }
    }
}

func number(_ v: Double) -> String { String(format: "%.5g", v) }
