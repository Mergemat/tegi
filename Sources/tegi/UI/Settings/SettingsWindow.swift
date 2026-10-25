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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "tegi.settings")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 820, height: 600))
        window.minSize = CGSize(width: 700, height: 460)
        window.center()
        window.setFrameAutosaveName("tegi.settings")
        return window
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case layout, workspaces, looks, motion, gestures, hotkeys, apps, about
    var id: Self { self }

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

    var symbol: String {
        switch self {
        case .layout: "rectangle.split.3x1.fill"
        case .workspaces: "square.stack.3d.up.fill"
        case .looks: "paintbrush.pointed.fill"
        case .motion: "sparkles"
        case .gestures: "hand.draw.fill"
        case .hotkeys: "keyboard.fill"
        case .apps: "app.badge.fill"
        case .about: "heart.fill"
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .layout: SwiftUI.Color(red: 0.25, green: 0.56, blue: 0.98)
        case .workspaces: SwiftUI.Color(red: 0.58, green: 0.42, blue: 0.95)
        case .looks: SwiftUI.Color(red: 0.98, green: 0.36, blue: 0.6)
        case .motion: SwiftUI.Color(red: 1, green: 0.58, blue: 0.16)
        case .gestures: SwiftUI.Color(red: 0.2, green: 0.74, blue: 0.48)
        case .hotkeys: SwiftUI.Color(red: 0.45, green: 0.47, blue: 0.55)
        case .apps: SwiftUI.Color(red: 0.13, green: 0.7, blue: 0.82)
        case .about: SwiftUI.Color(red: 1, green: 0.33, blue: 0.4)
        }
    }
}

let tegiBlue = SwiftUI.Color(red: 0.5, green: 0.78, blue: 1)
var tegiIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var pane: Pane? = .layout

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                HStack(spacing: 10) {
                    Image(nsImage: tegiIcon).resizable().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("tegi").font(.headline)
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .selectionDisabled()
                Section {
                    ForEach(Pane.allCases) { p in
                        Label { Text(p.title) } icon: { Badge(symbol: p.symbol, tint: p.tint) }
                            .tag(p)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            detail
                .navigationTitle((pane ?? .layout).title)
        }
        .environmentObject(model)
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
            switch pane ?? .layout {
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
struct Badge: View {
    let symbol: String
    let tint: SwiftUI.Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

/// A slider whose value shows beside it and is saved when let go.
struct SliderRow: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
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
        LabeledContent(title) {
            HStack(spacing: 10) {
                // Without a step: macOS draws a tick for every step, which crowds the track.
                Slider(value: Binding(get: { shown ?? value }, set: { shown = ($0 / step).rounded() * step }), in: range) {
                    EmptyView()
                } minimumValueLabel: {
                    Text(low ?? "").font(.caption).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text(high ?? "").font(.caption).foregroundStyle(.secondary)
                } onEditingChanged: { editing in
                    if !editing, let shown {
                        model.set(key, write(shown))
                        self.shown = nil
                    }
                }
                .frame(width: 230)
                if let format {
                    Text(format(shown ?? value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
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

/// A pane's preview: a little night-sky stage for the mascot.
struct Stage<Content: View>: View {
    var height: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                LinearGradient(colors: [SwiftUI.Color(red: 0.2, green: 0.22, blue: 0.48), SwiftUI.Color(red: 0.08, green: 0.09, blue: 0.22)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .listRowInsets(EdgeInsets())
            .listRowBackground(SwiftUI.Color.clear)
    }
}

/// tegi's mascot: a window with a face, wearing the focus ring.
struct Mascot: View {
    var ring: SwiftUI.Color = tegiBlue
    var ringWidth: CGFloat = 4
    var radius: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let ink = SwiftUI.Color(red: 0.12, green: 0.13, blue: 0.2)
            let blush = SwiftUI.Color(red: 1, green: 0.6, blue: 0.66).opacity(0.8)
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [.white, SwiftUI.Color(white: 0.9)], startPoint: .top, endPoint: .bottom))
                ZStack {
                    HStack(spacing: s * 0.26) {
                        Circle().fill(ink).frame(width: s * 0.1, height: s * 0.1)
                        Circle().fill(ink).frame(width: s * 0.1, height: s * 0.1)
                    }
                    HStack(spacing: s * 0.42) {
                        Ellipse().fill(blush).frame(width: s * 0.11, height: s * 0.07)
                        Ellipse().fill(blush).frame(width: s * 0.11, height: s * 0.07)
                    }
                    .offset(y: s * 0.08)
                    Circle().trim(from: 0.1, to: 0.4)
                        .stroke(ink, style: StrokeStyle(lineWidth: max(1.5, s * 0.035), lineCap: .round))
                        .frame(width: s * 0.18, height: s * 0.18)
                        .offset(y: -s * 0.02)
                }
                .offset(y: -geo.size.height * 0.18)
            }
            .overlay {
                if ringWidth > 0 {
                    RoundedRectangle(cornerRadius: radius + ringWidth, style: .continuous)
                        .strokeBorder(ring, lineWidth: ringWidth)
                        .padding(-ringWidth)
                        .shadow(color: ring.opacity(0.55), radius: 6)
                }
            }
        }
    }
}

/// A sleepy neighbour column.
struct Friend: View {
    var radius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [SwiftUI.Color(red: 0.56, green: 0.6, blue: 0.9), SwiftUI.Color(red: 0.4, green: 0.43, blue: 0.72)],
                                 startPoint: .top, endPoint: .bottom))
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
