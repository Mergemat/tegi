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
        let rules = model.shown.rules
        let startup = model.shown.startup
        Hero(height: 108) {
            ZStack {
                HStack(spacing: 8) {
                    Friend(radius: 7).frame(width: 40, height: 58)
                    Mascot(ringWidth: 2.5, radius: 8).frame(width: 48, height: 58)
                    Friend(radius: 7).frame(width: 40, height: 58)
                }
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: 36, height: 28)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .offset(x: 58, y: -20)
            }
        }

        CardTitle("Window rules")
        if rules.isEmpty {
            Card {
                Row(title: "No rules yet", detail: "Make an app float, open on a workspace, or start at a set width.", last: true) { EmptyView() }
            }
        }
        ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
            RuleCard(rule: rule) { changed in
                var list = rules
                if let changed { list[i] = changed } else { list.remove(at: i) }
                model.setList("rule", list.map(\.words))
            }
        }
        HStack {
            Button("Add a rule for an app…") {
                guard let id = chooseApp() else { return }
                var rule = WindowRule()
                rule.app = id
                rule.floating = true
                model.setList("rule", (rules + [rule]).map(\.words))
            }
            .buttonStyle(GummyButtonStyle(prominent: true))
            Spacer()
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, 22)

        CardTitle("Start with tegi")
        Card {
            ForEach(Array(startup.enumerated()), id: \.offset) { i, command in
                Row(title: title(of: command)) {
                    RemoveButton {
                        var list = startup
                        list.remove(at: i)
                        write(list)
                    }
                }
            }
            Row(title: "An app") {
                Button("Choose…") {
                    guard let id = chooseApp() else { return }
                    write(startup + [.spawn(["open", "-b", id])])
                }
                .buttonStyle(GummyButtonStyle())
            }
            Row(title: "Or a command", stacked: true, last: true) {
                HStack {
                    GummyField(prompt: "brew services start sketchybar", text: $shell, submit: addShell)
                    Button("Add", action: addShell).buttonStyle(GummyButtonStyle(prominent: true))
                        .disabled(shell.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
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

struct RuleCard: View {
    @EnvironmentObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    let rule: WindowRule
    let change: (WindowRule?) -> Void
    @State private var titleText = ""

    var body: some View {
        let t = Theme(scheme)
        Card {
            HStack(spacing: 10) {
                Image(nsImage: appIcon(rule.app == "*" ? nil : rule.app)).resizable().frame(width: 28, height: 28)
                Text(rule.app == nil || rule.app == "*" ? "Any app" : appName(rule.app!))
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(t.text)
                Spacer()
                RemoveButton { change(nil) }
            }
            .padding(.horizontal, Space.card)
            .padding(.vertical, 10)
            Rectangle().fill(t.divider).frame(height: 1).padding(.leading, Space.card)
            Row(title: "Opens", stacked: true) {
                Choice(options: [("As it likes", nil), ("Tiled", false), ("Floating", true)] as [(String, Bool?)], selected: rule.floating) { v in
                    var r = rule
                    r.floating = v
                    change(r)
                }
            }
            Row(title: "Width", stacked: true) {
                // Compared as written, so 1/3 matches the 0.33333 a saved rule reads back as.
                let widths: [(String, Double?)] = [("Default", nil), ("33%", 1.0 / 3), ("50%", 0.5), ("67%", 2.0 / 3), ("Full", 1)]
                Choice(options: widths.map { ($0.0, $0.1.map(number)) }, selected: rule.width.map(number)) { v in
                    var r = rule
                    r.width = v.flatMap { Double($0) }
                    change(r)
                }
            }
            Row(title: "Focus", stacked: true) {
                Choice(options: [("Takes it", nil), ("Stays behind", false)] as [(String, Bool?)], selected: rule.focused) { v in
                    var r = rule
                    r.focused = v
                    change(r)
                }
            }
            if !model.config.workspaces.isEmpty || rule.workspace != nil {
                Row(title: "Workspace", stacked: true) {
                    Choice(options: [("Current", nil)] + model.config.workspaces.map { ($0.name, Optional($0.name)) } as [(String, String?)],
                           selected: rule.workspace) { v in
                        var r = rule
                        r.workspace = v
                        change(r)
                    }
                }
            }
            Row(title: "Only windows titled", last: true) {
                GummyField(prompt: "any title", text: $titleText, width: 180) {
                    var r = rule
                    r.title = titleText.isEmpty ? nil : titleText
                    change(r)
                }
                .onAppear { titleText = rule.title ?? "" }
            }
        }
    }
}
