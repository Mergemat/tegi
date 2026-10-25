import AppKit
import SwiftUI
import TegiCore

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }

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

/// Chips for a list where any number may be picked; the picks come back in the choices' order.
struct Picks: View {
    let choices: [Column.Width]
    let chosen: [Column.Width]
    let change: ([Column.Width]) -> Void

    var body: some View {
        let picked = Set(chosen.map(\.text))
        FlowChips {
            ForEach(choices, id: \.text) { c in
                Chip(text: c.label, on: picked.contains(c.text)) {
                    let on = !picked.contains(c.text)
                    change(choices.filter { $0.text == c.text ? on : picked.contains($0.text) })
                }
            }
        }
    }
}

// MARK: Layout

struct LayoutPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let c = model.shown
        let fixed = c.presetColumnWidths.filter { if case .fixed = $0 { true } else { false } }
        Hero { StripScene(config: c) }

        CardTitle("Columns")
        Card {
            SliderRow(title: "Gap", detail: "Space between windows and around the edges.", key: ["gap"], value: c.gap, range: 0...64,
                      format: points, live: { $0.gap = $1 })
            SliderRow(title: "New column width", detail: "How wide a window opens.", key: ["default-column-width"],
                      value: c.defaultColumnWidth, range: 0.2...1, step: 0.05, format: percent, live: { $0.defaultColumnWidth = $1 })
            Row(title: "New columns show windows", last: true) {
                Choice(options: [("Stacked", false), ("As tabs", true)], selected: c.defaultColumnDisplayTabbed) {
                    model.set(["default-column-display"], [$0 ? "tabbed" : "normal"])
                }
            }
        }

        CardTitle("Sizes to cycle through")
        Card {
            Row(title: "Widths", detail: c.keys(for: .switchPresetColumnWidth).map { "\($0) steps through these." }, stacked: true) {
                Picks(choices: [0.25, 1.0 / 3, 0.4, 0.5, 0.6, 2.0 / 3, 0.75, 1].map { .proportion($0) } + fixed, chosen: c.presetColumnWidths) {
                    model.set(["preset-column-widths"], $0.isEmpty ? nil : $0.map(\.text))
                }
            }
            Row(title: "Heights", detail: "For windows stacked in one column.", stacked: true, last: true) {
                Picks(choices: [0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1].map { .proportion($0) }, chosen: c.presetWindowHeights.map { .proportion($0) }) {
                    model.set(["preset-window-heights"], $0.isEmpty ? nil : $0.map(\.text))
                }
            }
        }

        CardTitle("Scrolling")
        Card {
            Row(title: "Center the focused column", stacked: true) {
                Choice(options: [("Never", CenterMode.never), ("When it doesn't fit", .onOverflow), ("Always", .always)], selected: c.centerFocusedColumn) {
                    model.set(["center-focused-column"], [$0.rawValue])
                }
            }
            ToggleRow(title: "Center a lonely column", detail: "When it's the only one on its workspace.",
                      key: ["always-center-single-column"], isOn: c.alwaysCenterSingleColumn, last: true)
        }

        CardTitle("Screen edges")
        Card {
            Row(title: "Keep clear", detail: "Room for a dock or a bar, in points.", last: true) {
                let s = [c.struts.left, c.struts.right, c.struts.top, c.struts.bottom]
                HStack(spacing: 6) {
                    ForEach(Array(["L", "R", "T", "B"].enumerated()), id: \.offset) { i, side in
                        PointsField(side: side, value: s[i]) { v in
                            var next = s
                            next[i] = v
                            model.set(["struts"], next.map(number))
                        }
                    }
                }
            }
        }
    }
}

struct PointsField: View {
    @Environment(\.colorScheme) private var scheme
    let side: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        let t = Theme(scheme)
        HStack(spacing: 4) {
            Text(side).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(t.faint)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(t.text)
                .frame(width: 30)
                .onAppear { text = number(value) }
                .onChange(of: value) { text = number(value) }
                .onSubmit {
                    if let v = Double(text), (0...2000).contains(v) { commit(v) } else { text = number(value) }
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(t.chip, in: Capsule())
    }
}

/// The strip in miniature, drawn from the settings as they're being changed.
struct StripScene: View {
    let config: Config

    var body: some View {
        GeometryReader { geo in
            let gap = max(4, config.gap * 0.45)
            let height = geo.size.height - 22 - gap
            let column = config.defaultColumnWidth * (geo.size.width - 2 * gap) * 0.62
            let radius = config.windowCornerRadius * 0.6
            HStack(alignment: .bottom, spacing: gap) {
                Friend(radius: radius).frame(width: column, height: height)
                Mascot(ring: SwiftUI.Color(config.focusRingColor), ringWidth: config.focusRingWidth > 0 ? max(1.5, config.focusRingWidth * 0.75) : 0,
                       radius: radius)
                    .frame(width: column, height: height)
                Friend(radius: radius).frame(width: column, height: height)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .offset(y: 4)
        }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: config.gap)
        .animation(.spring(duration: 0.3, bounce: 0.25), value: config.defaultColumnWidth)
    }
}

// MARK: Workspaces

struct WorkspacesPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var newName = ""

    var body: some View {
        let c = model.shown
        Hero {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 4) {
                        Friend(radius: 4, face: false).frame(width: 40)
                        if row == 1 { Mascot(ringWidth: 2, radius: 4).frame(width: 40) } else { Friend(radius: 4, face: false).frame(width: 40) }
                        Friend(radius: 4, face: false).frame(width: 40)
                    }
                    .frame(height: 24)
                    .padding(4)
                    .background(.white.opacity(row == 1 ? 0.4 : 0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .opacity(row == 1 ? 1 : 0.6)
                }
            }
        }

        CardTitle("Switching")
        Card {
            ToggleRow(title: "Press again to go back", detail: "A workspace's key returns you to the one before.",
                      key: ["workspace-auto-back-and-forth"], isOn: c.workspaceAutoBackAndForth)
            ToggleRow(title: "An empty workspace on top", detail: "Besides the one always waiting at the bottom.",
                      key: ["empty-workspace-above-first"], isOn: c.emptyWorkspaceAboveFirst, last: true)
        }

        CardTitle("Named workspaces")
        Card {
            ForEach(Array(c.workspaces.enumerated()), id: \.offset) { i, ws in
                Row(title: ws.name, detail: "Reachable by name, and kept even when empty.") {
                    DisplayField(display: ws.display) { display in
                        var list = c.workspaces
                        list[i].display = display
                        model.setList("workspace", list.map(\.words))
                    }
                    RemoveButton {
                        var list = c.workspaces
                        list.remove(at: i)
                        model.setList("workspace", list.map(\.words))
                    }
                }
            }
            Row(title: "Add one", last: true) {
                GummyField(prompt: "chat, code…", text: $newName, width: 150, submit: add)
                Button("Add", action: add).buttonStyle(GummyButtonStyle(prominent: true))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private struct DisplayField: View {
        let display: String?
        let commit: (String?) -> Void
        @State private var text = ""

        var body: some View {
            GummyField(prompt: "Any display", text: $text, width: 130) {
                let name = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
                commit(name.isEmpty ? nil : name)
            }
            .onAppear { text = display ?? "" }
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty, Int(name) == nil, !model.config.workspaces.contains(where: { $0.name == name }) else { return }
        model.setList("workspace", (model.config.workspaces + [NamedWorkspace(name: name)]).map(\.words))
        newName = ""
    }
}

struct RemoveButton: View {
    let tap: () -> Void

    var body: some View {
        Button(action: tap) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
            .buttonStyle(GummyButtonStyle())
            .help("Remove")
    }
}

// MARK: Looks

struct LooksPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        let c = model.shown
        let ring = c.focusRingWidth > 0 ? max(1.5, c.focusRingWidth * 0.9) : 0
        let radius = c.windowCornerRadius * 0.9
        Hero(height: 132) {
            HStack(spacing: 46) {
                VStack(spacing: 6) {
                    Mascot(ring: SwiftUI.Color(c.focusRingColor), ringWidth: ring, radius: radius).frame(width: 62, height: 76)
                    SceneCaption("focused")
                }
                VStack(spacing: 6) {
                    Mascot(ring: SwiftUI.Color(c.focusRingInactiveColor), ringWidth: ring, radius: radius, asleep: true).frame(width: 62, height: 76)
                    SceneCaption("other displays")
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.3), value: c.focusRingWidth)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: c.windowCornerRadius)
        }

        CardTitle("Focus ring")
        Card {
            SliderRow(title: "Width", detail: "0 hides it.", key: ["focus-ring-width"], value: c.focusRingWidth, range: 0...12,
                      format: { $0 == 0 ? "off" : points($0) }, live: { $0.focusRingWidth = $1 })
            ColorRow(title: "Color", key: ["focus-ring-color"], color: c.focusRingColor) { $0.focusRingColor = $1 }
            ColorRow(title: "On your other displays", detail: "Marks their focused window.", key: ["focus-ring-inactive-color"],
                     color: c.focusRingInactiveColor, last: true) { $0.focusRingInactiveColor = $1 }
        }

        CardTitle("Windows")
        Card {
            SliderRow(title: "Corner radius", detail: "Match your apps so the ring hugs them.", key: ["window-corner-radius"],
                      value: c.windowCornerRadius, range: 0...30, last: true, format: points, live: { $0.windowCornerRadius = $1 })
        }

        CardTitle("Overview")
        Card {
            SliderRow(title: "Zoom", detail: "How small workspaces get.", key: ["overview-zoom"], value: c.overviewZoom,
                      range: 0.25...0.75, step: 0.05, format: percent, live: { $0.overviewZoom = $1 })
            ColorRow(title: "Backdrop", key: ["backdrop-color"], color: c.backdropColor, last: true) { $0.backdropColor = $1 }
        }
    }
}

struct SceneCaption: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme(scheme).secondary)
    }
}

struct ColorRow: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    var detail: String?
    let key: [String]
    let color: TegiCore.Color
    var last = false
    let live: (inout Config, TegiCore.Color) -> Void

    var body: some View {
        Row(title: title, detail: detail, last: last) {
            ColorDot(color: color) { picked in
                let hex = picked.hex
                model.setSoon(key, [hex]) { c in if let parsed = TegiCore.Color(hex: hex) { live(&c, parsed) } }
            }
        }
    }
}

// MARK: Motion

struct MotionPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var hop = false

    var body: some View {
        let a = model.shown.animations
        let spring = a.springs[.windowMovement] ?? Animations().springs[.windowMovement]!
        Hero(height: 124) {
            HStack(spacing: 8) {
                Friend(radius: 9).frame(width: 46, height: 66)
                Mascot(radius: 10).frame(width: 54, height: 66)
                Friend(radius: 9).frame(width: 46, height: 66)
            }
            .frame(maxWidth: .infinity, alignment: hop ? .trailing : .leading)
            .padding(.horizontal, 36)
            .animation(a.on ? springAnimation(spring, slowdown: a.slowdown) : nil, value: hop)
            SceneCaption("tap to play").frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture { hop.toggle() }

        CardTitle("Everything")
        Card {
            ToggleRow(title: "Animations", detail: "Off, or with macOS's Reduce Motion, windows jump into place.",
                      key: ["animations"], isOn: a.on, on: ["on"], off: ["off"])
            SliderRow(title: "Speed", detail: "Stretches every animation at once.", key: ["animation-slowdown"], value: -log2(a.slowdown),
                      range: -2...2, step: 0.25, last: true, format: { "\(number(pow(2, $0)))×" },
                      live: { $0.animations.slowdown = pow(2, -$1) }, write: { [number(pow(2, -$0))] })
        }

        CardTitle("Each animation")
        Card {
            ForEach(Array(Animations.Name.allCases.enumerated()), id: \.offset) { i, name in
                AnimationRow(name: name, last: i == Animations.Name.allCases.count - 1) { hop.toggle() }
            }
        }
        .opacity(a.on ? 1 : 0.5)
        .disabled(!a.on)
    }
}

func springAnimation(_ p: SpringParams, slowdown k: Double) -> Animation {
    .interpolatingSpring(mass: 1, stiffness: p.stiffness / (k * k), damping: 2 * p.dampingRatio * p.stiffness.squareRoot() / k)
}

struct AnimationRow: View {
    @EnvironmentObject var model: SettingsModel
    let name: Animations.Name
    let last: Bool
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
        let spring = model.shown.animations.springs[name]
        let key = ["animation", name.rawValue]
        Row(title: title, stacked: true, last: last && feel(spring) != .custom) {
            Choice(options: Feel.allCases.map { ($0.rawValue, $0) }, selected: feel(spring)) { f in
                switch f {
                case .off: model.set(key, ["off"])
                case .custom: write(SpringParams(dampingRatio: 0.8, stiffness: 650))
                default: write(params(f)!)
                }
            }
        }
        if let spring, feel(spring) == .custom {
            SliderRow(title: "Bounce", key: key, value: 1 - min(spring.dampingRatio, 1), range: 0...0.7, step: 0.05,
                      format: percent, live: { $0.animations.springs[name]?.dampingRatio = 1 - $1 },
                      write: { ["spring", "damping-ratio=\(number(1 - $0))", "stiffness=\(number(spring.stiffness))"] })
            SliderRow(title: "Stiffness", key: key, value: spring.stiffness, range: 150...2500, step: 10, last: last,
                      format: { "\(Int($0))" }, live: { $0.animations.springs[name]?.stiffness = $1 },
                      write: { ["spring", "damping-ratio=\(number(spring.dampingRatio))", "stiffness=\(number($0))"] })
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
        ("⌥ Option", "alt"), ("⌃ Control", "ctrl"), ("⌘ Command", "cmd"), ("⌥⇧", "alt+shift"), ("⌃⌥", "ctrl+alt"), ("None", "off"),
    ]

    var body: some View {
        let c = model.shown
        Hero(height: 124) {
            HStack(spacing: 30) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.55)).frame(width: 120, height: 76)
                        HStack(spacing: 10) {
                            ForEach(0..<3, id: \.self) { _ in Face().frame(width: 18, height: 18).shadow(color: .black.opacity(0.15), radius: 1, y: 1) }
                        }
                        Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(SwiftUI.Color(hex: 0x4f9dff)).offset(y: 24)
                    }
                    SceneCaption("three fingers slide the strip")
                }
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.55)).frame(width: 120, height: 76)
                        Image(systemName: "cursorarrow").font(.system(size: 16)).foregroundStyle(ink).offset(x: 6, y: 5)
                    }
                    SceneCaption("the corner opens the overview")
                }
            }
        }

        CardTitle("Trackpad")
        Card {
            ToggleRow(title: "Three-finger swipes", detail: "Sideways scrolls the strip, up and down switch workspaces, four fingers up opens the overview.",
                      key: ["three-finger-swipe"], isOn: c.threeFingerSwipe, last: !(threeFingerConflict && c.threeFingerSwipe), on: ["on"], off: ["off"])
            if threeFingerConflict && c.threeFingerSwipe {
                Row(title: "macOS uses three fingers too", detail: "Switch its swipes to four fingers so they don't fight.", last: true) {
                    Button("Trackpad settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                    }
                    .buttonStyle(GummyButtonStyle())
                }
            }
        }

        CardTitle("Modifier")
        Card {
            Row(title: "Hold to swipe and drag", detail: "Then two fingers or the wheel scroll the strip, dragging moves a window and right-dragging resizes it.",
                stacked: true, last: true) {
                Choice(options: Self.modifiers, selected: modifierName(c.swipeModifier)) { model.set(["swipe-modifier"], [$0]) }
            }
        }

        CardTitle("Pointer")
        Card {
            ToggleRow(title: "Hot corner", detail: "Push the pointer into the top-left corner to open the overview.",
                      key: ["hot-corner"], isOn: c.hotCorner, on: ["on"], off: ["off"])
            ToggleRow(title: "Focus follows the pointer", key: ["focus-follows-mouse"], isOn: c.focusFollowsMouse != nil)
            if let follow = c.focusFollowsMouse {
                SliderRow(title: "…and may scroll the strip", detail: "To reach a window that's partly off screen.", key: ["focus-follows-mouse"],
                          value: follow, range: 0...1, step: 0.05, format: percent, live: { $0.focusFollowsMouse = $1 },
                          write: { ["max-scroll-amount", "\(Int(($0 * 100).rounded()))%"] })
            }
            ToggleRow(title: "Pointer follows focus", detail: "Moves the pointer into windows you focus from the keyboard.",
                      key: ["warp-mouse-to-focus"], isOn: c.warpMouseToFocus, last: true)
        }
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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let t = Theme(scheme)
        VStack(spacing: 8) {
            Image(nsImage: tegiIcon).resizable().frame(width: 112, height: 112)
                .shadow(color: tegiBlue.opacity(0.45), radius: 16, y: 6)
            Text("Scrollable tiling for macOS").font(.system(size: 13, design: .rounded)).foregroundStyle(t.secondary)
            Text("Version \(version)").font(.system(size: 11.5, design: .rounded)).foregroundStyle(t.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)

        Card {
            Row(title: "Permissions", detail: "Accessibility and Screen Recording.") {
                Button("Check") { model.onPermissions() }.buttonStyle(GummyButtonStyle())
            }
            Row(title: "Every default, explained") {
                Button("Open") { NSWorkspace.shared.open(model.url.deletingLastPathComponent().appending(path: "defaults")) }
                    .buttonStyle(GummyButtonStyle())
            }
            Row(title: "Source and issues", last: true) {
                Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Mergemat/tegi")!) }
                    .buttonStyle(GummyButtonStyle())
            }
        }
        Text("Everything here lives in ~/.config/tegi/config, so you can edit it by hand too.")
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(t.faint)
            .padding(.horizontal, Space.page)
    }
}
