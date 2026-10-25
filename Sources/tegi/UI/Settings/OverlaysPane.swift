import SwiftUI
import TegiCore

struct OverlaysPane: View {
    @EnvironmentObject var model: SettingsModel

    private static let corners: [(String, Corner?)] = [("Off", nil), ("↖", .topLeft), ("↗", .topRight), ("↙", .bottomLeft), ("↘", .bottomRight)]
    // Compared as written, like every number read back from the config.
    private static let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    private static let delays: [(String, String)] = [("At once", "0"), ("A moment", "0.15"), ("A beat longer", "0.35")]

    var body: some View {
        let c = model.shown
        CardTitle("Overview")
        Card {
            OverviewScene(config: c)
                .animation(.spring(duration: 0.35, bounce: 0.2), value: c.overviewZoom)
                .animation(.spring(duration: 0.35, bounce: 0.2), value: c.overviewGap)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.card)
                .padding(.bottom, 6)
            SliderRow(title: "Zoom", detail: "How small workspaces get.", key: ["overview-zoom"], value: c.overviewZoom,
                      range: 0.25...0.75, step: 0.05, format: Self.percent, live: { $0.overviewZoom = $1 })
            SliderRow(title: "Space between", key: ["overview-gap"], value: c.overviewGap,
                      range: 0...0.3, step: 0.02, format: Self.percent, live: { $0.overviewGap = $1 })
            SliderRow(title: "Rounded corners", key: ["overview-workspace-radius"], value: c.overviewWorkspaceRadius,
                      range: 0...30, format: { "\(Int($0.rounded())) pt" }, live: { $0.overviewWorkspaceRadius = $1 })
            ToggleRow(title: "Workspace names", detail: "Their names, or numbers, in each corner.", key: ["overview-labels"],
                      isOn: c.overviewLabels, on: ["on"], off: ["off"])
            ToggleRow(title: "App icons", detail: "On each window, to tell them apart when small.", key: ["overview-icons"],
                      isOn: c.overviewIcons, on: ["on"], off: ["off"])
            Row(title: "Behind it", stacked: true) {
                Choice(options: [("Your wallpaper, blurred", OverviewBackdrop.wallpaper), ("A color", .color)], selected: c.overviewBackdrop) {
                    model.set(["overview-backdrop"], [$0.rawValue])
                }
            }
            if c.overviewBackdrop == .color {
                ColorRow(title: "Backdrop", key: ["backdrop-color"], color: c.backdropColor) { $0.backdropColor = $1 }
            }
            Row(title: "Hot corner", detail: "Push the pointer into this corner to open it.", stacked: true, last: true) {
                Choice(options: Self.corners, selected: c.hotCorner) { model.set(["hot-corner"], [$0?.rawValue ?? "off"]) }
            }
        }

        CardTitle("Window switcher")
        Card {
            SwitcherArt(icons: c.switcherShows == .icons, mascot: c.switcherMascot, ring: SwiftUI.Color(c.focusRingColor))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.card)
            Row(title: "Shows", stacked: true) {
                Choice(options: [("Window pictures", SwitcherShows.pictures), ("App icons", .icons)], selected: c.switcherShows) {
                    model.set(["switcher-shows"], [$0.rawValue])
                }
            }
            SliderRow(title: "Size", detail: "How tall each window shows.", key: ["switcher-size"], value: c.switcherSize,
                      range: 100...400, step: 10, format: { "\(Int($0)) pt" }, live: { $0.switcherSize = $1 })
            ToggleRow(title: "Window names", detail: "The picked window's name under the row.", key: ["switcher-names"],
                      isOn: c.switcherNames, on: ["on"], off: ["off"])
            Row(title: "Windows from", stacked: true) {
                Choice(options: [("Everywhere", SwitcherWindows.everywhere), ("This display", .display), ("This workspace", .workspace)],
                       selected: c.switcherWindows) { model.set(["switcher-windows"], [$0.rawValue]) }
            }
            Row(title: "Appears after", detail: "A quick tap switches without it flashing.", stacked: true) {
                Choice(options: Self.delays, selected: number(c.switcherDelay)) { model.set(["switcher-delay"], [$0]) }
            }
            ToggleRow(title: "The mascot peeks", key: ["switcher-mascot"], isOn: c.switcherMascot, last: true, on: ["on"], off: ["off"])
        }

        CardTitle("Hotkey cheat sheet")
        Card {
            Row(title: "Show it when tegi starts", stacked: true) {
                Choice(options: [("The first time", AtStartup.firstTime), ("Every time", .always), ("Never", .never)],
                       selected: c.hotkeyOverlayAtStartup) { model.set(["hotkey-overlay-at-startup"], [$0.rawValue]) }
            }
            Row(title: "See it now", last: true) {
                Button("Show") { model.onCheatSheet() }.buttonStyle(GummyButtonStyle())
            }
        }
    }
}

/// The switcher in miniature, following the settings: pictures or icons, and the mascot when it peeks.
private struct SwitcherArt: View {
    @Environment(\.colorScheme) private var scheme
    let icons: Bool
    let mascot: Bool
    let ring: SwiftUI.Color

    var body: some View {
        ZStack(alignment: .top) {
            if mascot { Mascot(ringWidth: 0, radius: 5).frame(width: 22, height: 26) }
            HStack(spacing: 8) {
                tile(picked: false)
                tile(picked: true)
                tile(picked: false)
            }
            .padding(10)
            .background(Theme(scheme).chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 13)
        }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: icons)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: mascot)
    }

    private func tile(picked: Bool) -> some View {
        Group {
            if icons {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [SwiftUI.Color(hex: 0x8fd0ff), SwiftUI.Color(hex: 0x5aa8ff)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 30, height: 30)
                    .padding(6)
            } else {
                Friend(radius: 5, face: false).frame(width: 52, height: 38)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: icons ? 12 : 8, style: .continuous)
                .strokeBorder(ring, lineWidth: 2.5)
                .padding(icons ? 1 : -4)
                .opacity(picked ? 1 : 0)
        }
        .scaleEffect(picked ? 1 : 0.92)
    }
}
