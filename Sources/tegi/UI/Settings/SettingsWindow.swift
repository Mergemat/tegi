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
        let window = NSWindow(contentViewController: hosting(SettingsView(model: model)))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "tegi Settings"
        chrome(window)
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 820, height: 660))
        window.minSize = CGSize(width: 720, height: 560)
        window.center()
        window.setFrameAutosaveName("tegi.settings")
        return window
    }
}

func hosting<V: View>(_ view: V) -> NSHostingController<V> {
    let hosting = NSHostingController(rootView: view)
    // Left to SwiftUI, a toolbar comes and goes with the content, and the window's corners and buttons move with it.
    hosting.sceneBridgingOptions = []
    return hosting
}

/// The same chrome for every tegi window: a hidden toolbar, so the buttons sit inset and the corners match.
func chrome(_ window: NSWindow) {
    window.toolbar = NSToolbar(identifier: "tegi")
    window.toolbarStyle = .unified
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
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
        case .gestures: "Gestures"
        case .hotkeys: "Hotkeys"
        case .apps: "Apps"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .layout: "How windows sit on the strip."
        case .workspaces: "The stack of workspaces on each display."
        case .looks: "The focus ring, corners and the overview."
        case .motion: "Every animation is a spring. Make it yours."
        case .gestures: "Swipes, the modifier and the pointer."
        case .hotkeys: "Every shortcut, grouped by what it does."
        case .apps: "Where apps open, and what starts with tegi."
        case .about: "Hello!"
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
        case .layout: SwiftUI.Color(hex: 0x5aa8ff)
        case .workspaces: SwiftUI.Color(hex: 0x9b7bff)
        case .looks: SwiftUI.Color(hex: 0xff7aa8)
        case .motion: SwiftUI.Color(hex: 0xffa94d)
        case .gestures: SwiftUI.Color(hex: 0x3fcf8e)
        case .hotkeys: SwiftUI.Color(hex: 0x8a90a8)
        case .apps: SwiftUI.Color(hex: 0x2fc4d8)
        case .about: SwiftUI.Color(hex: 0xff6b81)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("settings.pane") private var pane: Pane = .layout
    @State private var forward = true

    var body: some View {
        let t = Theme(scheme)
        HStack(alignment: .top, spacing: 18) {
            rail
            page(t)
        }
        .padding(.top, 4)
        .padding(.leading, 14)
        .padding([.trailing, .bottom], 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                t.background
                if t.night { Stars() }
            }
            .ignoresSafeArea()
        }
        .environmentObject(model)
        .tint(SwiftUI.Color(hex: 0x4f9dff))
    }

    // Sections are workspaces: the one you're on shows the mascot in its middle column.
    private var rail: some View {
        VStack(spacing: 3) {
            ForEach(Pane.allCases) { p in
                RailItem(pane: p, selected: p == pane) {
                    guard p != pane else { return }
                    forward = (Pane.allCases.firstIndex(of: p) ?? 0) > (Pane.allCases.firstIndex(of: pane) ?? 0)
                    withAnimation(.spring(duration: 0.45, bounce: 0.15)) { pane = p }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 140)
    }

    private func page(_ t: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(t.text)
                        Text(pane.subtitle).font(.system(size: 12.5, design: .rounded)).foregroundStyle(t.secondary)
                    }
                    Spacer(minLength: 0)
                    Peek(night: t.night, saves: model.saves).frame(width: 40, height: 48)
                }
                .padding(.horizontal, Space.page)
                .padding(.top, Space.page)
                .padding(.bottom, 18)
                if let problem = model.problem {
                    Label("Your config has a problem — \(problem). Changes won't save until it's fixed.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, Space.between)
                }
                content
                Footer()
            }
        }
        .scrollIndicators(.never)
        .id(pane)
        .transition(.asymmetric(insertion: .move(edge: forward ? .bottom : .top).combined(with: .opacity),
                                removal: .move(edge: forward ? .top : .bottom).combined(with: .opacity)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.page, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(t.edge))
        .shadow(color: .black.opacity(t.night ? 0.3 : 0.08), radius: 16, y: 6)
    }

    @ViewBuilder private var content: some View {
        switch pane {
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

struct RailItem: View {
    @Environment(\.colorScheme) private var scheme
    let pane: Pane
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        let t = Theme(scheme)
        HStack(spacing: 9) {
            Group {
                if selected {
                    Mascot(ringWidth: 0, radius: 7)
                } else {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: [pane.tint.opacity(0.8), pane.tint], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .frame(width: 22, height: 22)
            Text(pane.title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? t.text : t.railText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? (t.night ? tegiBlue.opacity(0.16) : .white) : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? tegiBlue.opacity(t.night ? 0.65 : 1) : .clear, lineWidth: 1.5))
        .shadow(color: selected && !t.night ? SwiftUI.Color(hex: 0x4f9dff, opacity: 0.2) : .clear, radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(perform: tap)
    }
}

/// The mascot by the page title: asleep at night, and it perks up whenever a change is saved.
struct Peek: View {
    let night: Bool
    let saves: Int
    @State private var hop = false

    var body: some View {
        Mascot(ringWidth: 0, radius: 11, asleep: night && !hop)
            .scaleEffect(hop ? 1.12 : 1, anchor: .bottom)
            .offset(y: hop ? -6 : 0)
            .onChange(of: saves) {
                withAnimation(.spring(duration: 0.3, bounce: 0.5)) { hop = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.spring(duration: 0.4)) { hop = false }
                }
            }
            .allowsHitTesting(false)
    }
}

struct Footer: View {
    @EnvironmentObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Open config file") { NSWorkspace.shared.open(model.url) }
                .buttonStyle(GummyButtonStyle())
            Button { NSWorkspace.shared.open(URL(string: "https://github.com/Mergemat/tegi#readme")!) } label: {
                Image(systemName: "questionmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(GummyButtonStyle())
            .help("tegi's guide")
        }
        .padding(.horizontal, Space.page)
        .padding(.top, 4)
        .padding(.bottom, Space.page)
    }
}

// MARK: Rows bound to settings

/// A slider row: the previews follow while it's dragged, and the config is written when it's let go.
struct SliderRow: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    var detail: String?
    let key: [String]
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var last = false
    let format: (Double) -> String
    let live: (inout Config, Double) -> Void
    var write: (Double) -> [String] = { [number($0)] }
    @State private var shown: Double?

    var body: some View {
        Row(title: title, detail: detail, last: last) {
            GummySlider(value: value, range: range, step: step) { v in
                shown = v
                model.preview { live(&$0, v) }
            } commit: { v in
                model.set(key, write(v))
                model.endPreview()
                shown = nil
            }
            ValueChip(text: format(shown ?? value))
        }
    }
}

struct ToggleRow: View {
    @EnvironmentObject var model: SettingsModel
    let title: String
    var detail: String?
    let key: [String]
    let isOn: Bool
    var last = false
    var on: [String]? = []
    var off: [String]?

    var body: some View {
        Row(title: title, detail: detail, last: last) {
            GummyToggle(isOn: isOn) { model.set(key, $0 ? on : off) }
        }
    }
}
