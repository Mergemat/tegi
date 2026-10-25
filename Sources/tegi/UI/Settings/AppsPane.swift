import AppKit
import SwiftUI
import TegiCore

private func chooseApp() -> String? {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

private func appName(_ id: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
}

private func appIcon(_ id: String?) -> NSImage {
    if let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil) ?? NSImage()
}

struct AppsPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var shell = ""

    var body: some View {
        let rules = model.config.rules
        let startup = model.config.startup
        Form {
            ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                RuleSection(rule: rule) { changed in
                    var list = rules
                    if let changed { list[i] = changed } else { list.remove(at: i) }
                    model.setList("rule", list.map(\.words))
                }
            }
            Section {
                Button("Add a Rule for an App…") {
                    guard let id = chooseApp() else { return }
                    var rule = WindowRule()
                    rule.app = id
                    rule.floating = true
                    model.setList("rule", (rules + [rule]).map(\.words))
                }
            } header: {
                if rules.isEmpty { Text("Window rules") }
            } footer: {
                Text("Make an app float, open on a workspace, or start at a set width. Every matching rule applies, in order.")
            }
            Section {
                ForEach(Array(startup.enumerated()), id: \.offset) { i, command in
                    LabeledContent(title(of: command)) {
                        Button {
                            var list = startup
                            list.remove(at: i)
                            write(list)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add an App…") {
                    guard let id = chooseApp() else { return }
                    write(startup + [.spawn(["open", "-b", id])])
                }
                HStack {
                    TextField("Command", text: $shell, prompt: Text("Or a shell command, like brew services start sketchybar"))
                        .onSubmit(addShell)
                    Button("Add", action: addShell).disabled(shell.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Start with tegi")
            }
        }
        .formStyle(.grouped)
    }

    private func addShell() {
        let line = shell.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        write(model.config.startup + [.spawnSh(line)])
        shell = ""
    }

    private func write(_ startup: [Command]) {
        model.setList("spawn-at-startup", startup.compactMap { if case .spawn(let a) = $0 { a } else { nil } })
        model.setList("spawn-sh-at-startup", startup.compactMap { if case .spawnSh(let s) = $0 { s.split(separator: " ").map(String.init) } else { nil } })
    }
}

struct RuleSection: View {
    @EnvironmentObject var model: SettingsModel
    let rule: WindowRule
    let change: (WindowRule?) -> Void
    @State private var titleText = ""

    var body: some View {
        Section {
            choice("Opens", rule.floating, [("As It Likes", nil), ("Tiled", false), ("Floating", true)]) { $0.floating = $1 }
            choice("Width", rule.width, [("Default", nil), ("33%", 1.0 / 3), ("50%", 0.5), ("67%", 2.0 / 3), ("Full", 1)]) { $0.width = $1 }
            choice("Focus", rule.focused, [("Takes It", nil), ("Stays Behind", false)]) { $0.focused = $1 }
            choice("Workspace", rule.workspace, [("Current", nil)] + model.config.workspaces.map { ($0.name, $0.name) }) { $0.workspace = $1 }
            LabeledContent("Only windows titled") {
                TextField("", text: $titleText, prompt: Text("Any title"))
                    .multilineTextAlignment(.trailing)
                    .onAppear { titleText = rule.title ?? "" }
                    .onSubmit {
                        var r = rule
                        r.title = titleText.isEmpty ? nil : titleText
                        change(r)
                    }
            }
        } header: {
            HStack(spacing: 8) {
                Image(nsImage: appIcon(rule.app == "*" ? nil : rule.app)).resizable().frame(width: 20, height: 20)
                Text(rule.app == nil || rule.app == "*" ? "Any app" : appName(rule.app!))
                Spacer()
                Button("Remove") { change(nil) }.buttonStyle(.borderless).font(.callout)
            }
        }
    }

    private func choice<V: Hashable>(_ label: String, _ value: V?, _ options: [(String, V?)], set: @escaping (inout WindowRule, V?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { value }, set: { v in
            var r = rule
            set(&r, v)
            change(r)
        })) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in Text(o.0).tag(o.1) }
        }
    }
}
