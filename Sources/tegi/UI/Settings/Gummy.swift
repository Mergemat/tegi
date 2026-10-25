import AppKit
import SwiftUI
import TegiCore

extension SwiftUI.Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    init(_ c: TegiCore.Color) { self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        let a = Int((c.alphaComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2]) + (a == 255 ? "" : String(format: "%02x", a))
    }
}

let tegiBlue = SwiftUI.Color(hex: 0x7fc8ff)
let ink = SwiftUI.Color(hex: 0x1a1c33)
let blush = SwiftUI.Color(hex: 0xff9fb0, opacity: 0.8)
let gummyBlue = LinearGradient(colors: [SwiftUI.Color(hex: 0x8fd3ff), SwiftUI.Color(hex: 0x4f9dff)], startPoint: .top, endPoint: .bottom)
var tegiIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

/// Day follows a light Mac, night a dark one; the shapes and spacing never change.
struct Theme {
    let night: Bool
    init(_ scheme: ColorScheme) { night = scheme == .dark }

    var background: LinearGradient {
        night ? LinearGradient(colors: [SwiftUI.Color(hex: 0x222766), SwiftUI.Color(hex: 0x0e1028)], startPoint: .topLeading, endPoint: .bottomTrailing)
              : LinearGradient(colors: [SwiftUI.Color(hex: 0xf4eeff), SwiftUI.Color(hex: 0xfff4ea), SwiftUI.Color(hex: 0xe8f3ff)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var page: LinearGradient {
        night ? LinearGradient(colors: [SwiftUI.Color(hex: 0x2b3070), SwiftUI.Color(hex: 0x1d2152)], startPoint: .top, endPoint: .bottom)
              : LinearGradient(colors: [.white, .white], startPoint: .top, endPoint: .bottom)
    }
    var hero: LinearGradient {
        night ? LinearGradient(colors: [SwiftUI.Color.white.opacity(0.1), SwiftUI.Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
              : LinearGradient(colors: [SwiftUI.Color(hex: 0xdfe9ff), SwiftUI.Color(hex: 0xf3eaff)], startPoint: .top, endPoint: .bottom)
    }
    var text: SwiftUI.Color { night ? .white : ink }
    var secondary: SwiftUI.Color { night ? .white.opacity(0.6) : SwiftUI.Color(hex: 0x7a7ea3) }
    var faint: SwiftUI.Color { night ? .white.opacity(0.5) : SwiftUI.Color(hex: 0x8a8db0) }
    var card: SwiftUI.Color { night ? .white.opacity(0.06) : SwiftUI.Color(hex: 0xf8f7ff) }
    var edge: SwiftUI.Color { night ? .white.opacity(0.07) : SwiftUI.Color(hex: 0x6e64be, opacity: 0.08) }
    var divider: SwiftUI.Color { night ? .white.opacity(0.07) : ink.opacity(0.06) }
    var chip: SwiftUI.Color { night ? .white.opacity(0.08) : SwiftUI.Color(hex: 0xefedff) }
    var chipText: SwiftUI.Color { night ? .white.opacity(0.72) : SwiftUI.Color(hex: 0x6a6e96) }
    var track: SwiftUI.Color { night ? .white.opacity(0.14) : SwiftUI.Color(hex: 0xe6e3f8) }
    var value: SwiftUI.Color { night ? tegiBlue.opacity(0.18) : SwiftUI.Color(hex: 0xeaf3ff) }
    var valueText: SwiftUI.Color { night ? tegiBlue : SwiftUI.Color(hex: 0x2f6fd6) }
    var rail: SwiftUI.Color { night ? .white.opacity(0.06) : .white.opacity(0.55) }
    var railText: SwiftUI.Color { night ? .white.opacity(0.7) : SwiftUI.Color(hex: 0x5b5f86) }
    var friend: [SwiftUI.Color] { night ? [SwiftUI.Color(hex: 0x9aa2f0), SwiftUI.Color(hex: 0x6670b8)] : [SwiftUI.Color(hex: 0xc7cdfa), SwiftUI.Color(hex: 0x9aa2f0)] }
}

// MARK: Layout pieces

/// The 8-point spacing every pane uses.
enum Space {
    static let page: CGFloat = 24
    static let card: CGFloat = 18
    static let between: CGFloat = 16
    static let row: CGFloat = 52
}

struct CardTitle: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(Theme(scheme).faint)
            .padding(.leading, Space.page)
            .padding(.bottom, 8)
    }
}

struct Card<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        let t = Theme(scheme)
        VStack(spacing: 0) { content }
            .background(t.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.edge))
            .padding(.horizontal, 16)
            .padding(.bottom, Space.between)
    }
}

/// One setting: what it is on the left, how to change it on the right (or below, when it needs the room).
struct Row<Control: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var detail: String?
    var stacked = false
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        let t = Theme(scheme)
        VStack(spacing: 0) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 10) {
                        label(t)
                        control
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 16) {
                        label(t)
                        Spacer(minLength: 0)
                        control
                    }
                }
            }
            .padding(.horizontal, Space.card)
            .padding(.vertical, 10)
            .frame(minHeight: Space.row)
            if !last { Rectangle().fill(t.divider).frame(height: 1).padding(.leading, Space.card) }
        }
    }

    private func label(_ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).foregroundStyle(t.text)
            if let detail {
                Text(detail).font(.system(size: 11.5, design: .rounded)).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The illustrated strip at the top of a page.
struct Hero<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var height: CGFloat = 116
    @ViewBuilder var content: Content

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme(scheme).hero, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }
}

// MARK: Controls

struct GummyToggle: View {
    @Environment(\.colorScheme) private var scheme
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(gummyBlue) : AnyShapeStyle(Theme(scheme).track))
                .overlay(Capsule().strokeBorder(.black.opacity(isOn ? 0.08 : 0)))
            Face(awake: isOn)
                .frame(width: 23, height: 23)
                .padding(2)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        }
        .frame(width: 46, height: 27)
        .contentShape(Capsule())
        .onTapGesture { set(!isOn) }
        .animation(.spring(duration: 0.3, bounce: 0.35), value: isOn)
    }
}

/// A round marshmallow face: the toggle's knob.
struct Face: View {
    var awake = true

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 23
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: 4.7 * s, y: 12.4 * s, width: 3.6 * s, height: 2 * s)), with: .color(blush))
            ctx.fill(Path(ellipseIn: CGRect(x: 14.7 * s, y: 12.4 * s, width: 3.6 * s, height: 2 * s)), with: .color(blush))
            if awake {
                ctx.fill(Path(ellipseIn: CGRect(x: 7.2 * s, y: 9.2 * s, width: 2.6 * s, height: 2.6 * s)), with: .color(ink))
                ctx.fill(Path(ellipseIn: CGRect(x: 13.2 * s, y: 9.2 * s, width: 2.6 * s, height: 2.6 * s)), with: .color(ink))
                var smile = Path()
                smile.move(to: CGPoint(x: 9.8 * s, y: 13.2 * s))
                smile.addQuadCurve(to: CGPoint(x: 13.2 * s, y: 13.2 * s), control: CGPoint(x: 11.5 * s, y: 14.9 * s))
                ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
            } else {
                for x in [7.0, 13.0] {
                    var lid = Path()
                    lid.move(to: CGPoint(x: x * s, y: 10.5 * s))
                    lid.addQuadCurve(to: CGPoint(x: (x + 3) * s, y: 10.5 * s), control: CGPoint(x: (x + 1.5) * s, y: 11.9 * s))
                    ctx.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
                }
            }
        }
    }
}

/// A slider whose knob is a little mascot head.
struct GummySlider: View {
    @Environment(\.colorScheme) private var scheme
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let change: (Double) -> Void
    let commit: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let shown = dragging ?? value
            let fraction = (min(max(shown, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme(scheme).track).frame(height: 5)
                Capsule().fill(LinearGradient(colors: [SwiftUI.Color(hex: 0x5aa8ff), tegiBlue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, width * fraction), height: 5)
                Knob().frame(width: 24, height: 24).offset(x: width * fraction - 12)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max(g.location.x / width, 0), 1)
                let v = ((range.lowerBound + f * (range.upperBound - range.lowerBound)) / step).rounded() * step
                if v != dragging {
                    dragging = v
                    change(v)
                }
            }.onEnded { _ in
                if let dragging { commit(dragging) }
                dragging = nil
            })
        }
        .frame(width: 180, height: 24)
    }
}

struct Knob: View {
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.white, SwiftUI.Color(hex: 0xdde2f5)], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(tegiBlue, lineWidth: 2.6)
            Face(awake: true).padding(4).blendMode(.multiply)
        }
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

struct ValueChip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        let t = Theme(scheme)
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(t.valueText)
            .padding(.vertical, 3)
            // A fixed width, so the slider beside it holds still while the value changes.
            .frame(width: 60)
            .background(t.value, in: Capsule())
    }
}

struct Chip: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let on: Bool
    let tap: () -> Void

    var body: some View {
        let t = Theme(scheme)
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(on ? SwiftUI.Color.white : t.chipText)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(on ? AnyShapeStyle(gummyBlue) : AnyShapeStyle(t.chip), in: Capsule())
            .shadow(color: SwiftUI.Color(hex: 0x4f9dff, opacity: on ? 0.35 : 0), radius: 4, y: 2)
            .contentShape(Capsule())
            .onTapGesture(perform: tap)
            .animation(.spring(duration: 0.25), value: on)
    }
}

/// One choice among a few, as chips.
struct Choice<Value: Equatable>: View {
    let options: [(String, Value)]
    let selected: Value
    let pick: (Value) -> Void

    var body: some View {
        FlowChips {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Chip(text: o.0, on: o.1 == selected) { pick(o.1) }
            }
        }
    }
}

/// Chips that wrap onto more lines when a row runs out of room.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { FlowLayout(spacing: 6) { content } }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(subviews, width: bounds.width).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}

/// A round swatch that opens the system color panel.
struct ColorDot: View {
    let color: TegiCore.Color
    let change: (SwiftUI.Color) -> Void

    var body: some View {
        Circle()
            .fill(SwiftUI.Color(color))
            .frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .contentShape(Circle())
            .onTapGesture { ColorWell.shared.open(NSColor(SwiftUI.Color(color))) { change(SwiftUI.Color(nsColor: $0)) } }
    }
}

final class ColorWell: NSObject {
    static let shared = ColorWell()
    private var change: ((NSColor) -> Void)?

    func open(_ color: NSColor, change: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.change = nil
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = color
        self.change = change
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { change?(panel.color) }
}

struct GummyButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let t = Theme(scheme)
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? SwiftUI.Color.white : t.text)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(gummyBlue) : AnyShapeStyle(t.chip), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct GummyField: View {
    @Environment(\.colorScheme) private var scheme
    let prompt: String
    @Binding var text: String
    var width: CGFloat?
    var submit: () -> Void = {}

    var body: some View {
        let t = Theme(scheme)
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(t.faint))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .rounded))
            .foregroundStyle(t.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(width: width)
            .background(t.chip, in: Capsule())
            .onSubmit(submit)
    }
}

struct KeyCap: View {
    let text: String
    var live = false

    var body: some View {
        Text(live ? "type keys…" : text)
            .font(.system(size: 12.5, weight: .semibold, design: live ? .rounded : .monospaced))
            .foregroundStyle(live ? SwiftUI.Color.white : ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 26)
            .background(live ? AnyShapeStyle(gummyBlue)
                             : AnyShapeStyle(LinearGradient(colors: [.white, SwiftUI.Color(hex: 0xd9ddf0)], startPoint: .top, endPoint: .bottom)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 0, y: 2)
    }
}

// MARK: The mascot and friends

/// tegi's mascot: a gummy window with a face, wearing the focus ring.
struct Mascot: View {
    var ring: SwiftUI.Color = tegiBlue
    var ringWidth: CGFloat = 4
    var radius: CGFloat = 14
    var asleep = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [.white, SwiftUI.Color(hex: 0xdfe3f6)], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let highlight = CGRect(x: w * 0.16, y: h * 0.05, width: w * 0.68, height: h * 0.12)
                ctx.fill(Path(roundedRect: highlight, cornerRadius: highlight.height / 2), with: .color(.white.opacity(0.75)))
                let eyeY = h * 0.34, eye = w * 0.095
                for x in [0.36, 0.64] {
                    if asleep {
                        var lid = Path()
                        lid.move(to: CGPoint(x: w * (x - 0.07), y: eyeY))
                        lid.addQuadCurve(to: CGPoint(x: w * (x + 0.07), y: eyeY), control: CGPoint(x: w * x, y: eyeY + h * 0.045))
                        ctx.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: max(1.2, w * 0.03), lineCap: .round))
                    } else {
                        ctx.fill(Path(ellipseIn: CGRect(x: w * x - eye / 2, y: eyeY - eye / 2, width: eye, height: eye)), with: .color(ink))
                        let shine = eye * 0.32
                        ctx.fill(Path(ellipseIn: CGRect(x: w * x - eye * 0.3, y: eyeY - eye * 0.35, width: shine, height: shine)), with: .color(.white))
                    }
                }
                for x in [0.27, 0.73] {
                    ctx.fill(Path(ellipseIn: CGRect(x: w * x - w * 0.065, y: h * 0.42, width: w * 0.13, height: h * 0.065)), with: .color(blush))
                }
                var smile = Path()
                smile.move(to: CGPoint(x: w * 0.43, y: h * 0.41))
                smile.addQuadCurve(to: CGPoint(x: w * 0.57, y: h * 0.41), control: CGPoint(x: w * 0.5, y: h * 0.47))
                ctx.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: max(1.4, w * 0.03), lineCap: .round))
            }
            if ringWidth > 0 {
                RoundedRectangle(cornerRadius: radius + ringWidth, style: .continuous)
                    .strokeBorder(ring, lineWidth: ringWidth)
                    .padding(-ringWidth)
                    .shadow(color: ring.opacity(0.6), radius: 6)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

/// A sleepy neighbour column.
struct Friend: View {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 14
    var face = true
    var tint: SwiftUI.Color?

    var body: some View {
        let colors = tint.map { [$0.opacity(0.55), $0.opacity(0.85)] } ?? Theme(scheme).friend
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let highlight = CGRect(x: w * 0.14, y: h * 0.06, width: w * 0.72, height: h * 0.1)
                ctx.fill(Path(roundedRect: highlight, cornerRadius: highlight.height / 2), with: .color(.white.opacity(0.2)))
                guard face, w > 24 else { return }
                for x in [0.34, 0.66] {
                    var lid = Path()
                    lid.move(to: CGPoint(x: w * (x - 0.07), y: h * 0.36))
                    lid.addQuadCurve(to: CGPoint(x: w * (x + 0.07), y: h * 0.36), control: CGPoint(x: w * x, y: h * 0.405))
                    ctx.stroke(lid, with: .color(SwiftUI.Color(hex: 0x1c2050, opacity: 0.55)), style: StrokeStyle(lineWidth: max(1.2, w * 0.03), lineCap: .round))
                }
            }
        }
    }
}

struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            for (x, y, r) in [(0.12, 0.08, 1.4), (0.86, 0.04, 1.6), (0.7, 0.96, 1.2), (0.06, 0.9, 1.0), (0.52, 0.02, 1.2),
                              (0.96, 0.5, 1.3), (0.03, 0.45, 0.9), (0.4, 0.98, 1.0), (0.98, 0.86, 1.1)] {
                ctx.fill(Path(ellipseIn: CGRect(x: x * size.width - r, y: y * size.height - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
    }
}
