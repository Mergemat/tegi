import Foundation

// Edits the user's config text one setting at a time, leaving every other line, comment and blank as it was.
public enum ConfigEditor {
    /// Sets the line whose first words are `key` (like ["gap"] or ["animation", "workspace-switch"]);
    /// nil removes it. A line that changes nothing from the defaults is left out.
    public static func set(_ key: [String], to args: [String]?, in text: String) -> String {
        let matches: ([String]) -> Bool = { $0.starts(with: key) }
        let without = replace(in: text, where: matches, with: [])
        guard let args else { return without }
        let with = replace(in: text, where: matches, with: [(key + args).joined(separator: " ")])
        if let a = try? Config.parse(with), let b = try? Config.parse(without), a == b { return without }
        return with
    }

    /// Whether the text has its own line for `key`, rather than using the default.
    public static func has(_ key: [String], in text: String) -> Bool {
        text.split(separator: "\n").contains { words($0).starts(with: key) }
    }

    /// Replaces every line of a repeated setting (rule, workspace, spawn-at-startup) with `lines`.
    public static func setList(_ name: String, to lines: [[String]], in text: String) -> String {
        replace(in: text, where: { $0.first == name }, with: lines.map { ([name] + $0).joined(separator: " ") })
    }

    /// Moves `command` from the `old` keys to the `new` ones; either may be nil to only add or only remove.
    public static func bind(_ command: Command, from old: KeyCombo?, to new: KeyCombo?, in text: String) -> String {
        var text = text
        if let old { text = keys(old, run: nil, in: text) }
        if let new { text = keys(new, run: command, in: text) }
        return text
    }

    private static func keys(_ combo: KeyCombo, run command: Command?, in text: String) -> String {
        let stripped = replace(in: text, where: { words in
            ["bind", "unbind"].contains(words.first) && words.count > 1 && KeyCombo(words[1]) == combo
        }, with: [])
        let current = (try? Config.parse(stripped))?.binds[combo]
        if current == command { return stripped }
        let line = command.map { "bind \(combo.description) " + $0.words.joined(separator: " ") } ?? "unbind \(combo.description)"
        return replace(in: stripped, where: { _ in false }, with: [line])
    }

    // Same tokenizing as the parser: a # word ends the line, a leading #word comments it out.
    static func words(_ line: Substring) -> [String] {
        var words: [String] = []
        for word in line.split(whereSeparator: \.isWhitespace) {
            if word == "#" || (word.hasPrefix("#") && words.isEmpty) { break }
            words.append(String(word))
        }
        return words
    }

    // New lines take the place of the first match, or go at the end.
    private static func replace(in text: String, where matches: ([String]) -> Bool, with new: [String]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var at: Int?
        var i = 0
        while i < lines.count {
            if matches(words(lines[i][...])) {
                at = at ?? i
                lines.remove(at: i)
            } else {
                i += 1
            }
        }
        if let at {
            lines.insert(contentsOf: new, at: at)
        } else if !new.isEmpty {
            if lines.last == "" { lines.insert(contentsOf: new, at: lines.count - 1) } else { lines += new + [""] }
        }
        return lines.joined(separator: "\n")
    }
}

extension SizeChange {
    var text: String {
        func number(_ v: Double) -> String { String(format: "%g", v) }
        switch self {
        case .setProportion(let p): return number(p * 100) + "%"
        case .adjustProportion(let p): return (p < 0 ? "" : "+") + number(p * 100) + "%"
        case .setFixed(let v): return number(v)
        case .adjustFixed(let v): return (v < 0 ? "" : "+") + number(v)
        }
    }
}

extension WorkspaceRef {
    var text: String {
        switch self {
        case .index(let n): return "\(n)"
        case .name(let s): return s
        }
    }
}

extension Command {
    /// The command as it's written in the config.
    public var words: [String] {
        if let name = Command.simple.first(where: { $0.value == self })?.key { return [name] }
        switch self {
        case .focusColumn(let n): return ["focus-column", "\(n)"]
        case .focusWindowInColumn(let n): return ["focus-window-in-column", "\(n)"]
        case .moveColumnToIndex(let n): return ["move-column-to-index", "\(n)"]
        case .moveWorkspaceToIndex(let n): return ["move-workspace-to-index", "\(n)"]
        case .focusWorkspace(let ref): return ["focus-workspace", ref.text]
        case .moveColumnToWorkspace(let ref): return ["move-column-to-workspace", ref.text]
        case .moveWindowToWorkspace(let ref): return ["move-window-to-workspace", ref.text]
        case .setWorkspaceName(let name): return ["set-workspace-name", name]
        case .focusMonitor(let d): return ["focus-monitor-" + d.rawValue]
        case .moveColumnToMonitor(let d): return ["move-column-to-monitor-" + d.rawValue]
        case .moveWindowToMonitor(let d): return ["move-window-to-monitor-" + d.rawValue]
        case .moveWorkspaceToMonitor(let d): return ["move-workspace-to-monitor-" + d.rawValue]
        case .setColumnWidth(let c): return ["set-column-width", c.text]
        case .setWindowHeight(let c): return ["set-window-height", c.text]
        case .setColumnDisplay(let tabbed): return ["set-column-display", tabbed ? "tabbed" : "normal"]
        case .nextWindow(let same): return ["next-window"] + (same ? ["same-app"] : [])
        case .previousWindow(let same): return ["previous-window"] + (same ? ["same-app"] : [])
        case .spawn(let args): return ["spawn"] + args
        case .spawnSh(let line): return ["spawn-sh"] + line.split(separator: " ").map(String.init)
        default: return []
        }
    }
}

extension WindowRule {
    /// The rule as written after `rule`.
    public var words: [String] {
        var w = [app ?? "*"]
        if let title { w += ["title", title] }
        if let floating { w.append(floating ? "float" : "tile") }
        if let width { w += ["width", String(format: "%.5g", width)] }
        if maximized == true { w.append("maximized") }
        if let focused { w.append(focused ? "focused" : "unfocused") }
        if let workspace { w += ["workspace", workspace] }
        if let display { w += ["display", display] }
        return w
    }
}

extension NamedWorkspace {
    /// The workspace as written after `workspace`.
    public var words: [String] { [name] + (display.map { ["display", $0] } ?? []) }
}
