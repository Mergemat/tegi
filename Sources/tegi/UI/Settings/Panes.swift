import AppKit
import SwiftUI
import TegiCore

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
private func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }

extension Config {
    func keys(for command: Command) -> String? {
        binds.filter { $0.value == command }.map { $0.key.symbol(hyper: mod) }.sorted().first
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
            Row(title: "New windows open", stacked: true) {
                VStack(alignment: .leading, spacing: 10) {
                    NewWindowArt(position: c.newWindowPosition)
                    Choice(options: [("Right of the focused one", NewWindowPosition.right), ("Left of it", .left), ("At the start", .start), ("At the end", .end)],
                           selected: c.newWindowPosition) { model.set(["new-window-position"], [$0.rawValue]) }
                }
            }
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
            Row(title: "Keep clear", detail: "Room for a dock or a bar, in points.", stacked: true, last: true) {
                EdgesScene(struts: c.struts) { model.set(["struts"], [$0.left, $0.right, $0.top, $0.bottom].map(number)) }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// The main display in miniature, true to its proportions: the bands kept clear along each edge, and the windows in what's left.
struct EdgesScene: View {
    let struts: Struts
    let commit: (Struts) -> Void

    var body: some View {
        VStack(spacing: 8) {
            field(\.top, "Top")
            HStack(spacing: 10) {
                field(\.left, "Left")
                screen
                field(\.right, "Right")
            }
            field(\.bottom, "Bottom")
        }
    }

    private func field(_ side: WritableKeyPath<Struts, Double>, _ name: String) -> some View {
        PointsField(value: struts[keyPath: side]) { v in
            var next = struts
            next[keyPath: side] = v
            commit(next)
        }
        .help(name)
    }

    private var screen: some View {
        let display = NSScreen.main ?? NSScreen.screens[0]
        let frame = display.frame, visible = display.visibleFrame
        let width = 280.0, k = width / frame.width
        // Struts are measured from the area the menu bar and Dock leave, as tegi applies them.
        let usable = CGRect(x: (visible.minX - frame.minX) * k, y: (frame.maxY - visible.maxY) * k,
                            width: visible.width * k, height: visible.height * k)
        let area = CGRect(x: usable.minX + struts.left * k, y: usable.minY + struts.top * k,
                          width: max(24, usable.width - (struts.left + struts.right) * k),
                          height: max(24, usable.height - (struts.top + struts.bottom) * k))
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [SwiftUI.Color(hex: 0x5b7cff), SwiftUI.Color(hex: 0xb18cff)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.5)).frame(width: width, height: usable.minY)
            Path { p in
                p.addRect(usable)
                p.addRect(area)
            }
            .fill(.white.opacity(0.4), style: FillStyle(eoFill: true))
            if area != usable {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.white, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
            }
            HStack(spacing: 5) {
                Friend(radius: 5)
                Mascot(ringWidth: 2, radius: 5)
                Friend(radius: 5)
            }
            .padding(7)
            .frame(width: area.width, height: area.height)
            .offset(x: area.minX, y: area.minY)
        }
        .frame(width: width, height: frame.height * k)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: struts)
    }
}

struct PointsField: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        let t = Theme(scheme)
        HStack(spacing: 3) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(t.text)
                .onAppear { text = number(value) }
                .onChange(of: value) { text = number(value) }
                .onSubmit {
                    if let v = Double(text), (0...2000).contains(v) { commit(v) } else { text = number(value) }
                }
            Text("pt").font(.system(size: 11, design: .rounded)).foregroundStyle(t.faint)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(width: 76)
        .background(t.chip, in: Capsule())
    }
}

/// A strip with the focused window in it, and a dashed new window where the setting would put it.
struct NewWindowArt: View {
    let position: NewWindowPosition
    private enum Tile: Hashable { case other(Int), focused, new }

    var body: some View {
        var strip: [Tile] = [.other(0), .other(1), .focused, .other(2)]
        let at = switch position {
        case .start: 0
        case .left: 2
        case .right: 3
        case .end: strip.count
        }
        strip.insert(.new, at: at)
        return HStack(spacing: 5) {
            ForEach(strip, id: \.self) { tile in
                switch tile {
                case .new:
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(tegiBlue, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .background(tegiBlue.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(tegiBlue))
                        .frame(width: 26, height: 34)
                case .focused: Mascot(ringWidth: 1.5, radius: 5).frame(width: 26, height: 34)
                case .other: Friend(radius: 5, face: false).frame(width: 26, height: 34).opacity(0.7)
                }
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: position)
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
            let radius = (config.windowCornerRadius ?? 16) * 0.6
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
        let radius = (c.windowCornerRadius ?? 16) * 0.9
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
            ToggleRow(title: "Fit each window's corners", detail: "The ring follows every window's own rounding.",
                      key: ["window-corner-radius"], isOn: c.windowCornerRadius == nil, last: c.windowCornerRadius == nil, on: nil, off: ["16"])
            if let radius = c.windowCornerRadius {
                SliderRow(title: "Corner radius", detail: "Used for every window.", key: ["window-corner-radius"],
                          value: radius, range: 0...30, last: true, format: points, live: { $0.windowCornerRadius = $1 })
            }
        }

    }
}

/// The overview in miniature, laid out as tegi lays it out: workspaces at the zoom, the current one centred, on the backdrop.
/// The overview in miniature, laid out as tegi lays it out, from the settings as they're being changed.
struct OverviewScene: View {
    let config: Config
    private let screen = CGSize(width: 240, height: 150)
    private static let paper = [SwiftUI.Color(hex: 0x5b7cff), SwiftUI.Color(hex: 0xb18cff)]

    var body: some View {
        let zoom = config.overviewZoom
        let step = screen.height * zoom * (1 + config.overviewGap)
        ZStack {
            ForEach(-2...2, id: \.self) { i in
                MiniWorkspace(current: i == 0, number: i + 2, config: config)
                    .frame(width: screen.width, height: screen.height)
                    .scaleEffect(zoom)
                    .offset(y: Double(i) * step)
            }
        }
        .frame(width: screen.width, height: screen.height)
        .background {
            if config.overviewBackdrop == .wallpaper {
                LinearGradient(colors: Self.paper, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blur(radius: 14)
                    .overlay(SwiftUI.Color.black.opacity(0.12))
            } else {
                SwiftUI.Color(config.backdropColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    fileprivate static var wallpaper: LinearGradient { LinearGradient(colors: paper, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

private struct MiniWorkspace: View {
    let current: Bool
    let number: Int
    let config: Config

    var body: some View {
        // Drawn at full size and scaled down with the zoom, so sizes meant to show at the overview's scale divide by it.
        let z = config.overviewZoom
        HStack(spacing: 10) {
            Friend(radius: 12).frame(width: 56)
            if current { Mascot(ringWidth: 4, radius: 13).frame(width: 84) } else { Friend(radius: 12).frame(width: 84) }
            Friend(radius: 12).frame(width: 56)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OverviewScene.wallpaper)
        .overlay(alignment: .topLeading) {
            if config.overviewLabels {
                Text("\(number)")
                    .font(.system(size: 8 / z, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5 / z).padding(.vertical, 1.5 / z)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6 / z)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: config.overviewWorkspaceRadius * 0.5 / z, style: .continuous))
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

struct DirectPane: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        Card {
            ToggleRow(title: "Direct mode",
                      detail: model.motionProblem ?? "Smoother motion, a live overview, and hidden windows gone completely. Needs SIP off.",
                      key: ["window-server-motion"], isOn: model.shown.animations.windowServer, last: true, on: ["on"], off: ["off"])
        }
    }
}

struct MotionPane: View {
    @EnvironmentObject var model: SettingsModel
    @State private var act = Animations.Name.windowMovement
    @State private var beat = false

    var body: some View {
        let a = model.shown.animations
        let spring = a.on ? a.springs[act] : nil
        Hero(height: 124) {
            Stage(act: act, beat: beat)
                .animation(spring.map { springAnimation($0, slowdown: a.slowdown) }, value: beat)
            SceneCaption("\(act.title) · tap to replay").frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 6)
        }
        .contentShape(Rectangle())
        .onTapGesture { play(act) }

        CardTitle("Everything")
        Card {
            ToggleRow(title: "Animations", detail: "Off, or with macOS's Reduce Motion, windows jump into place.",
                      key: ["animations"], isOn: a.on, on: ["on"], off: ["off"])
            SliderRow(title: "Speed", detail: "Stretches every animation at once.", key: ["animation-slowdown"], value: Double(speed(a.slowdown)),
                      range: 0...Double(Self.speeds.count - 1), last: true, format: { "\(number(Self.speeds[Int($0)]))×" },
                      live: { $0.animations.slowdown = 1 / Self.speeds[Int($1)] }, write: { [number(1 / Self.speeds[Int($0)])] })
        }

        CardTitle("Each animation")
        Card {
            ForEach(Array(Animations.Name.allCases.enumerated()), id: \.offset) { i, name in
                AnimationRow(name: name, last: i == Animations.Name.allCases.count - 1) { play(name) }
            }
        }
        .opacity(a.on ? 1 : 0.5)
        .disabled(!a.on)
    }

    // Round numbers with normal in the middle; even steps on a log scale land on speeds like 0.8409×.
    private static let speeds = [0.25, 0.5, 0.75, 1, 1.5, 2, 4]

    private func speed(_ slowdown: Double) -> Int {
        Self.speeds.indices.min { abs(log(Self.speeds[$0] * slowdown)) < abs(log(Self.speeds[$1] * slowdown)) }!
    }

    private func play(_ name: Animations.Name) {
        // A new act starts from its first pose, not from wherever the last one left the stage.
        if name != act {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                act = name
                beat = false
            }
        }
        DispatchQueue.main.async { beat.toggle() }
    }
}

/// Two workspaces of windows acting out one animation: the beat flips between its two poses.
struct Stage: View {
    let act: Animations.Name
    let beat: Bool
    private let height: CGFloat = 66, gap: CGFloat = 30

    var body: some View {
        let moved = act == .windowMovement && beat
        let overview = act == .overviewOpenClose && beat
        let scale: CGFloat = overview ? 0.55 : 1
        VStack(spacing: gap) {
            HStack(spacing: 8) {
                ForEach(moved ? [0, 2, 1] : [0, 1, 2], id: \.self) { i in
                    if i == 1 {
                        Mascot(radius: 10).frame(width: act == .windowResize && beat ? 110 : 54, height: height)
                    } else {
                        Friend(radius: 9).frame(width: 46, height: height)
                    }
                }
            }
            HStack(spacing: 8) {
                Friend(radius: 9).frame(width: 64, height: height)
                Friend(radius: 9).frame(width: 46, height: height)
            }
        }
        .scaleEffect(scale, anchor: .top)
        .offset(x: act == .horizontalViewMovement ? (beat ? -70 : 70) : 0,
                y: act == .workspaceSwitch && beat ? -(height + gap)
                    : overview ? height / 2 - scale * (2 * height + gap) / 2 : 0)
        .frame(height: height, alignment: .top)
    }
}

extension Animations.Name {
    var title: String {
        switch self {
        case .horizontalViewMovement: "Scrolling the strip"
        case .windowMovement: "Windows moving"
        case .windowResize: "Windows resizing"
        case .workspaceSwitch: "Switching workspaces"
        case .overviewOpenClose: "Opening the overview"
        }
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

    var body: some View {
        let spring = model.shown.animations.springs[name]
        let key = ["animation", name.rawValue]
        Row(title: name.title, stacked: true, last: last && feel(spring) != .custom) {
            Choice(options: Feel.allCases.map { ($0.rawValue, $0) }, selected: feel(spring)) { f in
                switch f {
                case .off:
                    model.set(key, ["off"])
                    played()
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
