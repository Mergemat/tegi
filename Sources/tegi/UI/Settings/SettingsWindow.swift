import AppKit
import SwiftUI
import TegiCore

final class SettingsWindow {
    let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) { self.model = model }

    func show() {
        let window = self.window ?? make()
        self.window = window
        model.reload()
        // Opened by a hotkey or the command line, tegi isn't the active app, and a plain activate leaves it behind.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "tegi.settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 780, height: 640))
        window.minSize = CGSize(width: 680, height: 480)
        window.center()
        window.setFrameAutosaveName("tegi.settings")
        return window
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case layout, workspaces, looks, motion, gestures, hotkeys, apps, about
    var id: Self { self }

    static let groups: [[Pane]] = [[.layout, .workspaces], [.looks, .motion], [.gestures, .hotkeys], [.apps]]

    var title: String {
        switch self {
        case .layout: "Layout"
        case .workspaces: "Workspaces"
        case .looks: "Looks"
        case .motion: "Motion"
        case .gestures: "Gestures & Mouse"
        case .hotkeys: "Hotkeys"
        case .apps: "Apps"
        case .about: "About tegi"
        }
    }

    /// Words a search in the sidebar finds this pane by.
    var keywords: String {
        switch self {
        case .layout: "gap column width presets height center struts edges tabs stacked"
        case .workspaces: "workspace named back forth empty display"
        case .looks: "focus ring color border corner radius overview zoom backdrop"
        case .motion: "animation spring speed bounce stiffness slow fast"
        case .gestures: "trackpad swipe fingers modifier option hot corner pointer mouse focus follows"
        case .hotkeys: "keys shortcuts bindings keyboard"
        case .apps: "rules float window app startup launch"
        case .about: "version config file github permissions"
        }
    }

    var symbol: String {
        switch self {
        case .layout: "rectangle.split.3x1.fill"
        case .workspaces: "square.stack.3d.up.fill"
        case .looks: "paintbrush.pointed.fill"
        case .motion: "wand.and.stars"
        case .gestures: "hand.draw.fill"
        case .hotkeys: "command"
        case .apps: "app.badge.fill"
        case .about: "heart.fill"
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .layout: SwiftUI.Color(red: 0.24, green: 0.55, blue: 0.98)
        case .workspaces: SwiftUI.Color(red: 0.55, green: 0.4, blue: 0.95)
        case .looks: SwiftUI.Color(red: 0.97, green: 0.35, blue: 0.6)
        case .motion: SwiftUI.Color(red: 1, green: 0.56, blue: 0.16)
        case .gestures: SwiftUI.Color(red: 0.18, green: 0.72, blue: 0.46)
        case .hotkeys: SwiftUI.Color(red: 0.43, green: 0.45, blue: 0.53)
        case .apps: SwiftUI.Color(red: 0.12, green: 0.68, blue: 0.82)
        case .about: SwiftUI.Color(red: 1, green: 0.33, blue: 0.4)
        }
    }
}

let tegiBlue = SwiftUI.Color(red: 0.5, green: 0.78, blue: 1)
var tegiIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("settings.pane") private var stored: Pane = .layout
    @State private var search = ""

    private var matches: [[Pane]] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Pane.groups }
        return Pane.groups.map { $0.filter { ($0.title + " " + $0.keywords).lowercased().contains(q) } }.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { stored }, set: { if let p = $0 { stored = p } })) {
                Section {
                    HStack(spacing: 10) {
                        Mascot(ringWidth: 2, radius: 6)
                            .frame(width: 26, height: 32)
                            .padding(5)
                            .background(Circle().fill(LinearGradient(colors: [SwiftUI.Color(red: 0.3, green: 0.34, blue: 0.75), SwiftUI.Color(red: 0.14, green: 0.16, blue: 0.42)],
                                                                     startPoint: .top, endPoint: .bottom)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("tegi").font(.system(size: 13, weight: .semibold))
                            Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Pane.about)
                }
                ForEach(Array(matches.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { p in
                            Label { Text(p.title) } icon: { Tile(symbol: p.symbol, tint: p.tint) }
                                .tag(p)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail.navigationTitle(stored.title)
        }
        .environmentObject(model)
        .tint(SwiftUI.Color(red: 0.3, green: 0.6, blue: 1))
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                Label("Your config has a problem — \(problem). Changes here won't save until it's fixed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.15))
            }
            switch stored {
            case .layout: LayoutPane()
            case .workspaces: WorkspacesPane()
            case .looks: LooksPane()
            case .motion: MotionPane()
            case .gestures: GesturesPane()
            case .hotkeys: HotkeysPane()
            case .apps: AppsPane()
            case .about: AboutPane()
            }
        }
    }
}

/// System Settings' colored icon tiles.
struct Tile: View {
    let symbol: String
    let tint: SwiftUI.Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// A slider with its end labels under the track, saved when let go.
struct SliderRow: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    var detail: String?
    let key: [String]
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var low: String?
    var high: String?
    var format: ((Double) -> String)?
    var write: (Double) -> [String] = { [number($0)] }
    @State private var shown: Double?

    var body: some View {
        LabeledContent {
            VStack(spacing: 3) {
                let binding = Binding(get: { shown ?? value }, set: { shown = ($0 / step).rounded() * step })
                let done: (Bool) -> Void = { editing in
                    if !editing, let shown {
                        model.set(key, write(shown))
                        self.shown = nil
                    }
                }
                // Ticks only for a handful of steps; any more and they crowd the track.
                if (range.upperBound - range.lowerBound) / step <= 12 {
                    Slider(value: binding, in: range, step: step, onEditingChanged: done)
                } else {
                    Slider(value: binding, in: range, onEditingChanged: done)
                }
                if low != nil || high != nil || format != nil {
                    HStack {
                        Text(low ?? "")
                        Spacer()
                        if let format { Text(format(shown ?? value)).monospacedDigit().foregroundStyle(.primary) }
                        Spacer()
                        Text(high ?? "")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240)
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

struct SettingToggle: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    var detail: String?
    let key: [String]
    let isOn: Bool
    var on: [String]? = []
    var off: [String]?

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { model.set(key, $0 ? on : off) })) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}

struct SettingColor: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    let key: [String]
    let color: TegiCore.Color

    var body: some View {
        ColorPicker(title, selection: Binding(get: { SwiftUI.Color(color) }, set: { model.set(key, [$0.hex]) }), supportsOpacity: true)
    }
}

/// A section title that keeps its weight and room right under the previews.
struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).padding(.top, 12)
    }
}

/// A section's footnote, left-aligned like System Settings'.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View { Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading) }
}

/// The illustrated cards at the top of a pane, like the ones in System Settings.
struct Previews<Content: View>: View {
    var height: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .frame(height: height)
            .listRowInsets(EdgeInsets())
            .listRowBackground(SwiftUI.Color.clear)
    }
}

struct PreviewCard<Content: View>: View {
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack { content }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    ZStack {
                        LinearGradient(colors: [SwiftUI.Color(red: 0.22, green: 0.25, blue: 0.56), SwiftUI.Color(red: 0.09, green: 0.1, blue: 0.25)],
                                       startPoint: .top, endPoint: .bottom)
                        Sparkles()
                    })
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
            if let caption {
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 5)
            }
        }
    }
}

struct Sparkles: View {
    var body: some View {
        Canvas { ctx, size in
            for (x, y, r) in [(0.12, 0.2, 1.4), (0.85, 0.15, 1.8), (0.7, 0.8, 1.2), (0.25, 0.75, 1.0), (0.5, 0.1, 1.1), (0.93, 0.6, 1.3), (0.05, 0.55, 0.9)] {
                let rect = CGRect(x: x * size.width - r, y: y * size.height - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.55)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The help button System Settings ends its panes with, next to a pane's actions.
struct PaneFooter: View {
    @EnvironmentObject var model: SettingsModel
    var help: String = "https://github.com/Mergemat/tegi#readme"

    var body: some View {
        HStack {
            Spacer()
            Button("Open Config File…") { NSWorkspace.shared.open(model.url) }
            Button { NSWorkspace.shared.open(URL(string: help)!) } label: { Image(systemName: "questionmark") }
                .buttonBorderShape(.circle)
                .help("tegi's guide")
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(SwiftUI.Color.clear)
    }
}

/// tegi's mascot: a gummy window with a face, wearing the focus ring.
struct Mascot: View {
    var ring: SwiftUI.Color = tegiBlue
    var ringWidth: CGFloat = 4
    var radius: CGFloat = 12
    var asleep = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let ink = SwiftUI.Color(red: 0.1, green: 0.11, blue: 0.2)
            let blush = SwiftUI.Color(red: 1, green: 0.55, blue: 0.64).opacity(0.75)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white, SwiftUI.Color(red: 0.88, green: 0.9, blue: 0.97)], startPoint: .top, endPoint: .bottom))
                ZStack {
                    HStack(spacing: s * 0.26) { eye(s, ink); eye(s, ink) }
                    HStack(spacing: s * 0.42) {
                        Ellipse().fill(blush).frame(width: s * 0.12, height: s * 0.075)
                        Ellipse().fill(blush).frame(width: s * 0.12, height: s * 0.075)
                    }
                    .offset(y: s * 0.085)
                    Circle().trim(from: 0.12, to: 0.38)
                        .stroke(ink, style: StrokeStyle(lineWidth: max(1.4, s * 0.034), lineCap: .round))
                        .frame(width: s * 0.2, height: s * 0.2)
                        .offset(y: -s * 0.025)
                }
                .offset(y: -geo.size.height * 0.16)
            }
            .shadow(color: .black.opacity(0.25), radius: s * 0.05, y: s * 0.03)
            .overlay {
                if ringWidth > 0 {
                    RoundedRectangle(cornerRadius: radius + ringWidth, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [ring.opacity(0.75), ring], startPoint: .top, endPoint: .bottom), lineWidth: ringWidth)
                        .padding(-ringWidth)
                        .shadow(color: ring.opacity(0.6), radius: 5)
                }
            }
        }
    }

    @ViewBuilder private func eye(_ s: CGFloat, _ ink: SwiftUI.Color) -> some View {
        if asleep {
            Circle().trim(from: 0.05, to: 0.45)
                .stroke(ink, style: StrokeStyle(lineWidth: max(1.2, s * 0.03), lineCap: .round))
                .frame(width: s * 0.11, height: s * 0.11)
        } else {
            Circle().fill(ink).frame(width: s * 0.1, height: s * 0.1)
                .overlay(Circle().fill(.white).frame(width: s * 0.03, height: s * 0.03).offset(x: -s * 0.015, y: -s * 0.018))
        }
    }
}

/// A sleepy neighbour column.
struct Friend: View {
    var radius: CGFloat = 12
    var face = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let ink = SwiftUI.Color(red: 0.14, green: 0.15, blue: 0.32).opacity(0.75)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [SwiftUI.Color(red: 0.6, green: 0.64, blue: 0.95), SwiftUI.Color(red: 0.4, green: 0.43, blue: 0.75)],
                                         startPoint: .top, endPoint: .bottom))
                if face && s > 30 {
                    HStack(spacing: s * 0.24) {
                        ForEach(0..<2, id: \.self) { _ in
                            Circle().trim(from: 0.05, to: 0.45)
                                .stroke(ink, style: StrokeStyle(lineWidth: max(1, s * 0.03), lineCap: .round))
                                .frame(width: s * 0.1, height: s * 0.1)
                        }
                    }
                    .offset(y: -geo.size.height * 0.16)
                }
            }
        }
    }
}

extension SwiftUI.Color {
    init(_ c: TegiCore.Color) { self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        let a = Int((c.alphaComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2]) + (a == 255 ? "" : String(format: "%02x", a))
    }
}
