import AppKit
import SwiftUI
import TegiCore

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

extension Config {
    func keys(for command: Command) -> String? {
        binds.filter { $0.value == command }.map(\.key.symbol).sorted().first
    }
}

extension Column.Width {
    var label: String {
        switch self {
        case .proportion(let p): return "\(Int((p * 100).rounded()))%"
        case .fixed(let px): return "\(Int(px)) pt"
        }
    }

    var text: String {
        switch self {
        case .proportion(let p): return number(p)
        case .fixed(let px): return "\(Int(px))px"
        }
    }
}

// MARK: Layout

struct LayoutPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let c = model.config
        let fixed = c.presetColumnWidths.filter { if case .fixed = $0 { true } else { false } }
        Form {
            Section {
                Stage(height: 160) { StripPreview(config: c) }
            }
            Section("Columns") {
                SliderRow(title: "Gap", key: ["gap"], value: c.gap, range: 0...64, format: { "\(Int($0)) pt" })
                SliderRow(title: "New column width", key: ["default-column-width"], value: c.defaultColumnWidth,
                          range: 0.2...1, step: 0.05, format: percent)
                Picker("New columns show windows", selection: Binding(get: { c.defaultColumnDisplayTabbed },
                                                                      set: { model.set(["default-column-display"], [$0 ? "tabbed" : "normal"]) })) {
                    Text("Stacked").tag(false)
                    Text("As Tabs").tag(true)
                }
            }
            Section {
                Presets(choices: [0.25, 1.0 / 3, 0.4, 0.5, 0.6, 2.0 / 3, 0.75, 1].map { .proportion($0) } + fixed,
                        chosen: c.presetColumnWidths) { model.set(["preset-column-widths"], $0.isEmpty ? nil : $0.map(\.text)) }
            } header: {
                Text("Widths to cycle through")
            } footer: {
                if let keys = c.keys(for: .switchPresetColumnWidth) { Text("\(keys) steps through these.") }
            }
            Section {
                Presets(choices: [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1].map { .proportion($0) },
                        chosen: c.presetWindowHeights.map { .proportion($0) }) {
                    model.set(["preset-window-heights"], $0.isEmpty ? nil : $0.map(\.text))
                }
            } header: {
                Text("Heights to cycle through")
            } footer: {
                Text("For windows stacked in one column.")
            }
            Section("Scrolling") {
                Picker("Center the focused column", selection: Binding(get: { c.centerFocusedColumn },
                                                                       set: { model.set(["center-focused-column"], [$0.rawValue]) })) {
                    Text("Never").tag(CenterMode.never)
                    Text("When It Doesn't Fit").tag(CenterMode.onOverflow)
                    Text("Always").tag(CenterMode.always)
                }
                SettingToggle(title: "Center a column that's alone", key: ["always-center-single-column"], isOn: c.alwaysCenterSingleColumn)
            }
            Section {
                let s = [c.struts.left, c.struts.right, c.struts.top, c.struts.bottom]
                ForEach(Array(["Left", "Right", "Top", "Bottom"].enumerated()), id: \.offset) { i, side in
                    LabeledContent(side) {
                        PointsField(value: s[i]) { v in
                            var next = s
                            next[i] = v
                            model.set(["struts"], next.map(number))
                        }
                    }
                }
            } header: {
                Text("Screen edges")
            } footer: {
                Text("Space kept clear on every display, for a dock or a bar.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Toggle buttons for each choice; the chosen ones come back in the choices' order.
struct Presets: View {
    let choices: [Column.Width]
    let chosen: [Column.Width]
    let change: ([Column.Width]) -> Void

    var body: some View {
        let picked = Set(chosen.map(\.text))
        HStack(spacing: 6) {
            ForEach(choices, id: \.text) { choice in
                Toggle(choice.label, isOn: Binding(get: { picked.contains(choice.text) }, set: { on in
                    change(choices.filter { $0.text == choice.text ? on : picked.contains($0.text) })
                }))
                .toggleStyle(.button)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PointsField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .onAppear { text = number(value) }
                .onChange(of: value) { text = number(value) }
                .onSubmit {
                    if let v = Double(text), (0...2000).contains(v) { commit(v) } else { text = number(value) }
                }
            Text("pt").foregroundStyle(.secondary)
        }
    }
}

/// The strip in miniature, drawn from the current settings.
struct StripPreview: View {
    let config: Config

    var body: some View {
        GeometryReader { geo in
            let gap = max(3, config.gap * 0.4)
            let height = geo.size.height - 2 * gap
            let column = config.defaultColumnWidth * (geo.size.width - 2 * gap)
            let radius = config.windowCornerRadius * 0.5
            HStack(spacing: gap) {
                Friend(radius: radius).frame(width: column, height: height)
                Mascot(ring: SwiftUI.Color(config.focusRingColor), ringWidth: config.focusRingWidth > 0 ? max(1.5, config.focusRingWidth * 0.6) : 0,
                       radius: radius)
                    .frame(width: column, height: height)
                Friend(radius: radius).frame(width: column, height: height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: config.gap)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: config.defaultColumnWidth)
    }
}

// MARK: Workspaces

struct WorkspacesPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var newName = ""

    var body: some View {
        let c = model.config
        Form {
            Section("Switching") {
                SettingToggle(title: "Press a workspace's key again to go back", detail: "Returns to the workspace you were on before.",
                              key: ["workspace-auto-back-and-forth"], isOn: c.workspaceAutoBackAndForth)
                SettingToggle(title: "Keep an empty workspace on top", detail: "Besides the one always waiting at the bottom.",
                              key: ["empty-workspace-above-first"], isOn: c.emptyWorkspaceAboveFirst)
            }
            Section {
                ForEach(Array(c.workspaces.enumerated()), id: \.offset) { i, ws in
                    LabeledContent(ws.name) {
                        HStack {
                            DisplayField(display: ws.display) { display in
                                var list = c.workspaces
                                list[i].display = display
                                model.setList("workspace", list.map(\.words))
                            }
                            Button {
                                var list = c.workspaces
                                list.remove(at: i)
                                model.setList("workspace", list.map(\.words))
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("New workspace", text: $newName, prompt: Text("Name, like chat"))
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Named workspaces")
            } footer: {
                Text("They stay even when empty and can be reached by name. Pin one to a display by the display's name.")
            }
        }
        .formStyle(.grouped)
    }

    private struct DisplayField: View {
        let display: String?
        let commit: (String?) -> Void
        @State private var text = ""

        var body: some View {
            TextField("", text: $text, prompt: Text("Any display"))
                .multilineTextAlignment(.trailing)
                .frame(width: 140)
                .onAppear { text = display ?? "" }
                .onSubmit {
                    let name = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                    commit(name.isEmpty ? nil : name)
                }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, Int(name) == nil, !model.config.workspaces.contains(where: { $0.name == name }) else { return }
        model.setList("workspace", (model.config.workspaces + [NamedWorkspace(name: name)]).map(\.words))
        newName = ""
    }
}

// MARK: Looks

struct LooksPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let c = model.config
        let ring = c.focusRingWidth > 0 ? max(1.5, c.focusRingWidth * 0.9) : 0
        Form {
            Section {
                Stage(height: 170) {
                    HStack(spacing: 34) {
                        Mascot(ring: SwiftUI.Color(c.focusRingColor), ringWidth: ring, radius: c.windowCornerRadius * 0.8)
                            .frame(width: 92, height: 112)
                        Mascot(ring: SwiftUI.Color(c.focusRingInactiveColor), ringWidth: ring, radius: c.windowCornerRadius * 0.8)
                            .frame(width: 92, height: 112)
                            .opacity(0.85)
                    }
                    .animation(.spring(duration: 0.35, bounce: 0.3), value: c.focusRingWidth)
                    .animation(.spring(duration: 0.35, bounce: 0.3), value: c.windowCornerRadius)
                }
            }
            Section {
                SliderRow(title: "Width", key: ["focus-ring-width"], value: c.focusRingWidth, range: 0...12, format: { $0 == 0 ? "Off" : "\(Int($0)) pt" })
                SettingColor(title: "Color", key: ["focus-ring-color"], color: c.focusRingColor)
                SettingColor(title: "Color on other displays", key: ["focus-ring-inactive-color"], color: c.focusRingInactiveColor)
            } header: {
                Text("Focus ring")
            } footer: {
                Text("The ring around the focused window. On displays you're not using, the second color marks their focused window.")
            }
            Section {
                SliderRow(title: "Corner radius", key: ["window-corner-radius"], value: c.windowCornerRadius, range: 0...30, format: { "\(Int($0)) pt" })
            } header: {
                Text("Windows")
            } footer: {
                Text("Match your apps' corners so the ring hugs them.")
            }
            Section("Overview") {
                SliderRow(title: "Zoom", key: ["overview-zoom"], value: c.overviewZoom, range: 0.25...0.75, step: 0.05,
                          low: "Small", high: "Big", format: percent)
                SettingColor(title: "Backdrop", key: ["backdrop-color"], color: c.backdropColor)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Motion

struct MotionPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var hop = false

    var body: some View {
        let a = model.config.animations
        let spring = a.springs[.windowMovement] ?? Animations().springs[.windowMovement]!
        Form {
            Section {
                Stage(height: 150) {
                    Mascot(radius: 10).frame(width: 64, height: 78)
                        .frame(maxWidth: .infinity, alignment: hop ? .trailing : .leading)
                        .padding(.horizontal, 60)
                        .animation(a.on ? springAnimation(spring, slowdown: a.slowdown) : nil, value: hop)
                    Text("Click to play").font(.caption).foregroundStyle(.white.opacity(0.6))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
                }
                .contentShape(Rectangle())
                .onTapGesture { hop.toggle() }
            }
            Section {
                SettingToggle(title: "Animations", detail: "When off, or with macOS's Reduce Motion, windows jump into place.",
                              key: ["animations"], isOn: a.on, on: ["on"], off: ["off"])
                SliderRow(title: "Speed", key: ["animation-slowdown"], value: -log2(a.slowdown), range: -2...2, step: 0.25,
                          low: "Slower", high: "Faster", write: { [number(pow(2, -$0))] })
                    .disabled(!a.on)
            }
            Section("Each animation") {
                ForEach(Animations.Name.allCases, id: \.self) { name in
                    AnimationRow(name: name) { hop.toggle() }
                }
            }
            .disabled(!a.on)
        }
        .formStyle(.grouped)
    }
}

func springAnimation(_ p: SpringParams, slowdown k: Double) -> Animation {
    .interpolatingSpring(mass: 1, stiffness: p.stiffness / (k * k), damping: 2 * p.dampingRatio * p.stiffness.squareRoot() / k)
}

struct AnimationRow: View {
    @EnvironmentObject var model: SettingsModel
    let name: Animations.Name
    let played: () -> Void

    enum Feel: String, CaseIterable { case off = "Off", snappy = "Snappy", smooth = "Smooth", gentle = "Gentle", bouncy = "Bouncy", custom = "Custom" }

    private var fallback: SpringParams { Animations().springs[name]! }

    private func params(_ feel: Feel) -> SpringParams? {
        switch feel {
        case .snappy: SpringParams(dampingRatio: 1, stiffness: 1400)
        case .smooth: fallback
        case .gentle: SpringParams(dampingRatio: 1, stiffness: 420)
        case .bouncy: SpringParams(dampingRatio: 0.62, stiffness: 700)
        case .off, .custom: nil
        }
    }

    private func feel(_ p: SpringParams?) -> Feel {
        guard let p else { return .off }
        return [Feel.snappy, .smooth, .gentle, .bouncy].first { f in
            params(f).map { $0.dampingRatio == p.dampingRatio && $0.stiffness == p.stiffness } ?? false
        } ?? .custom
    }

    private var title: String {
        switch name {
        case .horizontalViewMovement: "Scrolling the strip"
        case .windowMovement: "Windows moving"
        case .windowResize: "Windows resizing"
        case .workspaceSwitch: "Switching workspaces"
        case .overviewOpenClose: "Opening the overview"
        }
    }

    var body: some View {
        let spring = model.config.animations.springs[name]
        let key = ["animation", name.rawValue]
        Picker(title, selection: Binding(get: { feel(spring) }, set: { f in
            switch f {
            case .off: model.set(key, ["off"])
            case .custom: write(SpringParams(dampingRatio: 0.8, stiffness: 650))
            default: write(params(f)!)
            }
        })) {
            ForEach(Feel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        if let spring, feel(spring) == .custom {
            SliderRow(title: "Bounce", key: key, value: 1 - min(spring.dampingRatio, 1), range: 0...0.7, step: 0.05, low: "None", high: "Lots",
                      write: { ["spring", "damping-ratio=\(number(1 - $0))", "stiffness=\(number(spring.stiffness))"] })
                .padding(.leading, 16)
            SliderRow(title: "Stiffness", key: key, value: spring.stiffness, range: 150...2500, step: 10, low: "Soft", high: "Stiff",
                      write: { ["spring", "damping-ratio=\(number(spring.dampingRatio))", "stiffness=\(number($0))"] })
                .padding(.leading, 16)
        }
    }

    private func write(_ p: SpringParams) {
        model.set(["animation", name.rawValue], ["spring", "damping-ratio=\(number(p.dampingRatio))", "stiffness=\(number(p.stiffness))"])
        played()
    }
}

// MARK: Gestures

struct GesturesPane: View {
    @EnvironmentObject var model: SettingsModel

    private static let modifiers: [(String, String)] = [
        ("⌥ Option", "alt"), ("⌃ Control", "ctrl"), ("⌘ Command", "cmd"), ("⌥⇧ Option-Shift", "alt+shift"),
        ("⌃⌥ Control-Option", "ctrl+alt"), ("None", "off"),
    ]

    var body: some View {
        let c = model.config
        Form {
            Section("Trackpad") {
                SettingToggle(title: "Three-finger swipes", detail: "Sideways scrolls the strip, up and down switch workspaces, four fingers up opens the overview.",
                              key: ["three-finger-swipe"], isOn: c.threeFingerSwipe, on: ["on"], off: ["off"])
                if threeFingerConflict && c.threeFingerSwipe {
                    LabeledContent {
                        Button("Trackpad Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                        }
                    } label: {
                        Label("macOS uses three fingers too. Switch its swipes to four fingers.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Picker("Hold to swipe and drag", selection: Binding(get: { modifierName(c.swipeModifier) }, set: { model.set(["swipe-modifier"], [$0]) })) {
                    ForEach(Self.modifiers, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("Modifier")
            } footer: {
                Text("While held, two fingers or the mouse wheel scroll the strip, dragging moves a window, and right-dragging resizes it.")
            }
            Section("Pointer") {
                SettingToggle(title: "Hot corner", detail: "Push the pointer into the top-left corner to open the overview.",
                              key: ["hot-corner"], isOn: c.hotCorner, on: ["on"], off: ["off"])
                SettingToggle(title: "Focus follows the pointer", key: ["focus-follows-mouse"], isOn: c.focusFollowsMouse != nil)
                if let follow = c.focusFollowsMouse {
                    SliderRow(title: "Scroll to reach a window", key: ["focus-follows-mouse"], value: follow, range: 0...1, step: 0.05,
                              low: "Never", high: "Fully", format: percent,
                              write: { ["max-scroll-amount", "\(Int(($0 * 100).rounded()))%"] })
                }
                SettingToggle(title: "Pointer follows focus", detail: "Moves the pointer into windows you focus with the keyboard.",
                              key: ["warp-mouse-to-focus"], isOn: c.warpMouseToFocus)
            }
        }
        .formStyle(.grouped)
    }

    private var threeFingerConflict: Bool {
        let trackpad = UserDefaults.standard.persistentDomain(forName: "com.apple.AppleMultitouchTrackpad")
        return (trackpad?["TrackpadThreeFingerHorizSwipeGesture"] as? Int ?? 0) != 0
            || (trackpad?["TrackpadThreeFingerVertSwipeGesture"] as? Int ?? 0) != 0
    }

    private func modifierName(_ m: Mods) -> String {
        if m.isEmpty { return "off" }
        var parts: [String] = []
        if m.contains(.ctrl) { parts.append("ctrl") }
        if m.contains(.alt) { parts.append("alt") }
        if m.contains(.shift) { parts.append("shift") }
        if m.contains(.cmd) { parts.append("cmd") }
        return parts.joined(separator: "+")
    }
}

// MARK: About

struct AboutPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: tegiIcon).resizable().frame(width: 128, height: 128)
                        .shadow(color: tegiBlue.opacity(0.4), radius: 16, y: 6)
                    Text("tegi").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Scrollable tiling for macOS").foregroundStyle(.secondary)
                    Text("Version \(version)").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            Section {
                LabeledContent("Config file") {
                    Button("Open") { NSWorkspace.shared.open(model.url) }
                }
                LabeledContent("Every default, explained") {
                    Button("Open") { NSWorkspace.shared.open(model.url.deletingLastPathComponent().appending(path: "defaults")) }
                }
                LabeledContent("Source and issues") {
                    Link("GitHub", destination: URL(string: "https://github.com/Mergemat/tegi")!)
                }
            } footer: {
                Text("Everything here is saved to ~/.config/tegi/config, so you can edit it by hand too.")
            }
        }
        .formStyle(.grouped)
    }
}
