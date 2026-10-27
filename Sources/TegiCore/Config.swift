import Foundation

public enum CenterMode: String {
    case never, always
    case onOverflow = "on-overflow"
}

public struct Mods: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let cmd = Mods(rawValue: 1)
    public static let alt = Mods(rawValue: 2)
    public static let ctrl = Mods(rawValue: 4)
    public static let shift = Mods(rawValue: 8)
    public static let meh: Mods = [.ctrl, .alt, .shift]
    public static let hyper: Mods = [.ctrl, .alt, .shift, .cmd]
    /// What Raycast, Tinycast and Hyperkey send for Hyper unless their Include Shift is on.
    public static let hyperWithoutShift: Mods = [.ctrl, .alt, .cmd]

    /// The keys `mod+self` stands for. A mod that already holds Shift can't add it, so its Shift layer is ⌥⇧.
    public func under(_ mod: Mods) -> Mods { contains(.shift) && mod.contains(.shift) ? union(.alt) : union(mod) }

    /// As a config names it: alt, ctrl+alt, hyper.
    public var text: String { String(KeyCombo(keyCode: 0, mods: self)!.description.dropLast(2)) }
}

public struct KeyCombo: Hashable, CustomStringConvertible {
    public var keyCode: UInt32
    public var mods: Mods
    public var key: String
    public var description: String

    public static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.mods == b.mods }
    public func hash(into h: inout Hasher) {
        h.combine(keyCode)
        h.combine(mods)
    }
}

public struct Color: Equatable {
    public var red, green, blue, alpha: Double

    public init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9,
              let v = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let rgba = hex.count == 7 ? v << 8 | 0xff : v
        red = Double(rgba >> 24 & 0xff) / 255
        green = Double(rgba >> 16 & 0xff) / 255
        blue = Double(rgba >> 8 & 0xff) / 255
        alpha = Double(rgba & 0xff) / 255
    }
}

public struct WindowRule: Equatable {
    public var app: String?
    public var title: String?
    public var floating: Bool?
    public var width: Double?
    public var maximized: Bool?
    public var focused: Bool?
    public var workspace: String?
    public var display: String?

    public init() {}

    public func matches(app bundle: String?, title windowTitle: String) -> Bool {
        if let app, app != "*", app != bundle { return false }
        if let title, windowTitle.range(of: title, options: .regularExpression) == nil { return false }
        return true
    }

    /// A tile rule means an app's windows, not its menus, popovers and dialogs.
    public func floats(tileable: Bool, popup: Bool) -> Bool { popup || (floating ?? !tileable) }

    mutating func merge(_ o: WindowRule) {
        floating = o.floating ?? floating
        width = o.width ?? width
        maximized = o.maximized ?? maximized
        focused = o.focused ?? focused
        workspace = o.workspace ?? workspace
        display = o.display ?? display
    }
}

public struct NamedWorkspace: Equatable {
    public var name: String
    public var display: String?

    public init(name: String, display: String? = nil) {
        self.name = name
        self.display = display
    }
}

public struct Animations: Equatable {
    public enum Name: String, CaseIterable {
        case horizontalViewMovement = "horizontal-view-movement"
        case windowMovement = "window-movement"
        case windowResize = "window-resize"
        case workspaceSwitch = "workspace-switch"
        case overviewOpenClose = "overview-open-close"
    }

    public var on = true
    public var windowServer = false
    public var slowdown = 1.0
    public var springs: [Name: SpringParams] = [
        .horizontalViewMovement: .view, .windowMovement: .view, .windowResize: .view,
        .workspaceSwitch: .workspace, .overviewOpenClose: .view,
    ]

    public init() {}

    public func spring(_ name: Name) -> SpringParams? { on ? springs[name] : nil }
}

public enum Corner: String, CaseIterable {
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
}

/// Where a new window's column goes: beside the focused one, or at either end of the strip.
public enum NewWindowPosition: String, CaseIterable { case right, left, start, end }

public enum OverviewBackdrop: String, CaseIterable { case wallpaper, color }
public enum SwitcherShows: String, CaseIterable { case pictures, icons, both }
public enum SwitcherWindows: String, CaseIterable { case everywhere, display, workspace }
public enum AtStartup: String, CaseIterable { case firstTime = "first-time", always, never }

public struct Struts: Equatable {
    public var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0

    public func inset(_ area: CGRect) -> CGRect {
        CGRect(x: area.minX + left, y: area.minY + top,
               width: max(100, area.width - left - right), height: max(100, area.height - top - bottom))
    }

    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) {
        (self.left, self.right, self.top, self.bottom) = (left, right, top, bottom)
    }
}

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public struct Config: Equatable {
    public var gap: Double = 16
    public var defaultColumnWidth: Double = 0.5
    public var presetColumnWidths: [Column.Width] = [.proportion(1.0 / 3), .proportion(0.5), .proportion(2.0 / 3)]
    public var struts = Struts()
    public var presetWindowHeights: [Double] = [1.0 / 3, 0.5, 2.0 / 3]
    public var centerFocusedColumn: CenterMode = .never
    public var alwaysCenterSingleColumn = false
    public var workspaceAutoBackAndForth = false
    public var animations = Animations()
    public var swipeModifier: Mods = .alt
    public var overviewZoom = 0.5
    public var hotCorner: Corner? = .topLeft
    /// Between workspaces in the overview, as a share of a workspace's height.
    public var overviewGap = 0.1
    /// In points as the overview shows them, whatever the zoom.
    public var overviewWorkspaceRadius = 14.0
    public var overviewLabels = true
    public var overviewIcons = true
    public var overviewBackdrop = OverviewBackdrop.wallpaper
    public var switcherShows = SwitcherShows.pictures
    public var switcherWindows = SwitcherWindows.everywhere
    /// Seconds ⌥Tab is held before the switcher shows, so a quick tap switches without it flashing.
    public var switcherDelay = 0.15
    public var switcherMascot = false
    /// The height of each window in the switcher, in points; a short screen caps it.
    public var switcherSize = 220.0
    public var switcherNames = true
    public var hotkeyOverlayAtStartup = AtStartup.firstTime
    public var threeFingerSwipe = true
    public var focusFollowsMouse: Double?
    public var warpMouseToFocus = false
    public var backdropColor = Color(hex: "#262626")!
    public var focusRingWidth: Double = 4
    public var focusRingColor = Color(hex: "#7fc8ff")!
    public var focusRingInactiveColor = Color(hex: "#505050")!
    /// nil follows each window's own corners.
    public var windowCornerRadius: Double?
    public var rules: [WindowRule] = []
    public var workspaces: [NamedWorkspace] = []
    public var defaultColumnDisplayTabbed = false
    public var newWindowPosition = NewWindowPosition.right
    public var emptyWorkspaceAboveFirst = false
    public var startup: [Command] = []

    public func rule(app: String?, title: String) -> WindowRule {
        var merged = WindowRule()
        for r in rules where r.matches(app: app, title: title) { merged.merge(r) }
        return merged
    }
    /// Your key: shortcuts written as mod+… use it, and move with it.
    public var mod: Mods = .alt { didSet { resolve() } }
    /// Shortcuts written on your key, by the keys pressed besides it.
    var onMod: [KeyCombo: Command] = [:] { didSet { resolve() } }
    var fixed: [KeyCombo: Command] = [:] { didSet { resolve() } }
    /// Every shortcut on its actual keys. Kept rather than worked out on each read: every keypress and every settings row reads it.
    public private(set) var binds: [KeyCombo: Command] = [:]

    private mutating func resolve() {
        var all: [KeyCombo: Command] = [:]
        for (shape, command) in onMod {
            if let combo = KeyCombo(keyCode: shape.keyCode, mods: shape.mods.under(mod)) { all[combo] = command }
        }
        binds = all.merging(fixed) { _, fixed in fixed }
    }

    /// The keys a config line names: mod+… is resolved against your key.
    static func combo(_ text: String, mod: Mods) -> (combo: KeyCombo, shape: KeyCombo?)? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard parts.first == "mod" else { return KeyCombo(text).map { ($0, nil) } }
        guard let shape = KeyCombo(parts.dropFirst().joined(separator: "+")),
              let combo = KeyCombo(keyCode: shape.keyCode, mods: shape.mods.under(mod)) else { return nil }
        return (combo, shape)
    }

    /// How a config line names `combo`: on your key when it's there, so it moves when your key does.
    static func written(_ combo: KeyCombo, mod: Mods) -> String {
        let extras = [combo.mods.isSuperset(of: mod) ? combo.mods.subtracting(mod) : nil,
                      mod.contains(.shift) && combo.mods.isSuperset(of: [.alt, .shift]) ? combo.mods.subtracting(.alt) : nil]
        for case let extra? in extras where extra.under(mod) == combo.mods {
            guard let shape = KeyCombo(keyCode: combo.keyCode, mods: extra) else { break }
            return "mod+" + shape.description
        }
        return combo.description
    }

    static func modifiers(_ text: String) -> Mods? {
        guard let combo = KeyCombo(text + "+a"), !combo.mods.isEmpty else { return nil }
        return combo.mods
    }

    public init() {}

    public static let builtIn = try! parse(defaultsText, over: Config())

    public static func parse(_ text: String, over base: Config = builtIn) throws(ConfigError) -> Config {
        var config = base
        var seen: [String: Int] = [:]
        var bound: Set<KeyCombo> = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Every mod+… line means the same key wherever the mod line sits.
        for raw in lines {
            let words = raw.split(whereSeparator: \.isWhitespace)
            if words.count == 2, words[0] == "mod", let mod = modifiers(String(words[1])) { config.mod = mod }
        }
        for (index, raw) in lines.enumerated() {
            let line = index + 1
            var words: [String] = []
            for word in raw.split(whereSeparator: \.isWhitespace) {
                if word == "#" || (word.hasPrefix("#") && words.isEmpty) { break }
                words.append(String(word))
            }
            guard let name = words.first else { continue }
            let args = Array(words.dropFirst())
            func fail(_ message: String) -> ConfigError { ConfigError(line: line, message: message) }
            if !["bind", "unbind", "rule", "animation", "workspace", "spawn-at-startup", "spawn-sh-at-startup"].contains(name) {
                if let first = seen[name] { throw fail("\(name) is already set on line \(first)") }
                seen[name] = line
            }
            func fraction(_ s: String) throws(ConfigError) -> Double {
                guard let v = Double(s), v > 0, v <= 1 else { throw fail("\(s) is not a fraction between 0 and 1") }
                return v
            }
            func one() throws(ConfigError) -> String {
                guard args.count == 1 else { throw fail("\(name) takes one value") }
                return args[0]
            }
            func fractions() throws(ConfigError) -> [Double] {
                guard !args.isEmpty else { throw fail("list at least one fraction") }
                var out: [Double] = []
                for a in args { out.append(try fraction(a)) }
                return out.sorted()
            }
            func number(_ range: ClosedRange<Double>, _ message: String) throws(ConfigError) -> Double {
                guard let v = Double(try one()), range.contains(v) else { throw fail(message) }
                return v
            }
            func color() throws(ConfigError) -> Color {
                guard let c = Color(hex: try one()) else { throw fail("write colors as #rrggbb or #rrggbbaa") }
                return c
            }
            func flag() throws(ConfigError) -> Bool {
                guard args.isEmpty else { throw fail("\(name) takes no value; delete the line to turn it off") }
                return true
            }

            switch name {
            case "gap":
                config.gap = try number(0...200, "gap must be between 0 and 200 points")
            case "focus-ring-width":
                config.focusRingWidth = try number(0...20, "focus-ring-width must be between 0 and 20 points")
            case "focus-ring-color":
                config.focusRingColor = try color()
            case "focus-ring-inactive-color":
                config.focusRingInactiveColor = try color()
            case "window-corner-radius":
                if args == ["auto"] {
                    config.windowCornerRadius = nil
                } else {
                    config.windowCornerRadius = try number(0...40, "window-corner-radius is auto or between 0 and 40 points")
                }
            case "new-window-position":
                guard let v = NewWindowPosition(rawValue: try one()) else { throw fail("new-window-position is right, left, start or end") }
                config.newWindowPosition = v
            case "default-column-width":
                config.defaultColumnWidth = try fraction(try one())
            case "preset-column-widths":
                guard !args.isEmpty else { throw fail("list at least one width") }
                var widths: [Column.Width] = []
                for a in args {
                    if a.hasSuffix("px") {
                        guard let px = Double(a.dropLast(2)), px >= 50, px <= 20_000 else { throw fail("\(a) isn't a width in points") }
                        widths.append(.fixed(px))
                    } else {
                        widths.append(.proportion(try fraction(a)))
                    }
                }
                config.presetColumnWidths = widths
            case "struts":
                guard args.count == 4, let v = Optional(args.compactMap(Double.init)), v.count == 4, v.allSatisfy({ (0...2000).contains($0) }) else {
                    throw fail("write struts <left> <right> <top> <bottom> in points")
                }
                config.struts = Struts(left: v[0], right: v[1], top: v[2], bottom: v[3])
            case "preset-window-heights":
                config.presetWindowHeights = try fractions()
            case "always-center-single-column":
                config.alwaysCenterSingleColumn = try flag()
            case "animations":
                switch try one() {
                case "on": config.animations.on = true
                case "off": config.animations.on = false
                default: throw fail("animations is on or off")
                }
            case "window-server-motion":
                switch try one() {
                case "on": config.animations.windowServer = true
                case "off": config.animations.windowServer = false
                default: throw fail("window-server-motion is on or off")
                }
            case "animation-slowdown":
                config.animations.slowdown = try number(0.05...20, "animation-slowdown must be between 0.05 and 20")
            case "animation":
                guard let first = args.first, let anim = Animations.Name(rawValue: first) else {
                    if ["window-open", "window-close"].contains(args.first ?? "") {
                        throw fail("tegi doesn't animate \(args[0]): a new or closing window can't be scaled or faded")
                    }
                    throw fail("animation is one of " + Animations.Name.allCases.map(\.rawValue).joined(separator: ", "))
                }
                if let earlier = seen["animation " + first] { throw fail("\(first) is already set on line \(earlier)") }
                seen["animation " + first] = line
                let rest = args.dropFirst()
                if rest == ["off"] {
                    config.animations.springs[anim] = nil
                    continue
                }
                guard rest.first == "spring" else { throw fail("write animation \(first) spring damping-ratio=1.0 stiffness=800 epsilon=0.0001, or off") }
                var spring = Animations().springs[anim]!
                for pair in rest.dropFirst() {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2, let v = Double(kv[1]) else { throw fail("write \(pair) as key=value") }
                    switch kv[0] {
                    case "damping-ratio" where (0.1...10).contains(v): spring.dampingRatio = v
                    case "stiffness" where (1...100_000).contains(v): spring.stiffness = v
                    case "epsilon" where v > 0 && v < 1: spring.epsilon = v
                    default: throw fail("\(pair) is out of range or unknown; use damping-ratio, stiffness and epsilon")
                    }
                }
                config.animations.springs[anim] = spring
            case "mod":
                guard modifiers(try one()) != nil else { throw fail("mod is alt, ctrl+alt, cmd+alt, hyper, meh, or another combination") }
            case "swipe-modifier":
                let v = try one()
                if v == "off" {
                    config.swipeModifier = []
                } else {
                    guard let mods = modifiers(v) else { throw fail("swipe-modifier is alt, ctrl, cmd, shift, a combination like alt+shift, or off") }
                    config.swipeModifier = mods
                }
            case "three-finger-swipe":
                switch try one() {
                case "on": config.threeFingerSwipe = true
                case "off": config.threeFingerSwipe = false
                default: throw fail("three-finger-swipe is on or off")
                }
            case "focus-follows-mouse":
                if args.isEmpty {
                    config.focusFollowsMouse = 1
                } else {
                    guard args.count == 2, args[0] == "max-scroll-amount", args[1].hasSuffix("%"),
                          let p = Double(args[1].dropLast()), (0...100).contains(p) else {
                        throw fail("write focus-follows-mouse, optionally followed by max-scroll-amount <percent>")
                    }
                    config.focusFollowsMouse = p / 100
                }
            case "warp-mouse-to-focus":
                config.warpMouseToFocus = try flag()
            case "hot-corner":
                let v = try one()
                if v == "off" {
                    config.hotCorner = nil
                } else if v == "on" {
                    config.hotCorner = .topLeft
                } else {
                    guard let corner = Corner(rawValue: v) else { throw fail("hot-corner is top-left, top-right, bottom-left, bottom-right or off") }
                    config.hotCorner = corner
                }
            case "overview-gap":
                config.overviewGap = try number(0...0.5, "overview-gap is between 0 and 0.5 of a workspace's height")
            case "overview-workspace-radius":
                config.overviewWorkspaceRadius = try number(0...40, "overview-workspace-radius is between 0 and 40 points")
            case "overview-labels", "overview-icons":
                let on: Bool
                switch try one() {
                case "on": on = true
                case "off": on = false
                default: throw fail("\(name) is on or off")
                }
                if name == "overview-labels" { config.overviewLabels = on } else { config.overviewIcons = on }
            case "overview-backdrop":
                guard let v = OverviewBackdrop(rawValue: try one()) else { throw fail("overview-backdrop is wallpaper or color") }
                config.overviewBackdrop = v
            case "switcher-shows":
                guard let v = SwitcherShows(rawValue: try one()) else { throw fail("switcher-shows is pictures, icons or both") }
                config.switcherShows = v
            case "switcher-windows":
                guard let v = SwitcherWindows(rawValue: try one()) else { throw fail("switcher-windows is everywhere, display or workspace") }
                config.switcherWindows = v
            case "switcher-delay":
                config.switcherDelay = try number(0...1, "switcher-delay is between 0 and 1 second")
            case "switcher-size":
                config.switcherSize = try number(80...400, "switcher-size is between 80 and 400 points")
            case "switcher-names":
                switch try one() {
                case "on": config.switcherNames = true
                case "off": config.switcherNames = false
                default: throw fail("switcher-names is on or off")
                }
            case "switcher-mascot":
                switch try one() {
                case "on": config.switcherMascot = true
                case "off": config.switcherMascot = false
                default: throw fail("switcher-mascot is on or off")
                }
            case "hotkey-overlay-at-startup":
                guard let v = AtStartup(rawValue: try one()) else { throw fail("hotkey-overlay-at-startup is first-time, always or never") }
                config.hotkeyOverlayAtStartup = v
            case "overview-zoom":
                config.overviewZoom = try number(0.1...0.75, "overview-zoom must be between 0.1 and 0.75")
            case "backdrop-color":
                config.backdropColor = try color()
            case "workspace-auto-back-and-forth":
                config.workspaceAutoBackAndForth = try flag()
            case "center-focused-column":
                guard let mode = CenterMode(rawValue: try one()) else { throw fail("use never, always or on-overflow") }
                config.centerFocusedColumn = mode
            case "rule":
                guard let bundle = args.first, args.count >= 2 else {
                    throw fail("write rule <bundle-id or *> [title <regex>] followed by what to do")
                }
                var rule = WindowRule()
                rule.app = bundle
                var rest = args.dropFirst()[...]
                func value(_ option: String) throws(ConfigError) -> String {
                    guard let v = rest.popFirst() else { throw fail("\(option) needs a value") }
                    return v
                }
                while let word = rest.popFirst() {
                    switch word {
                    case "title":
                        let pattern = try value(word)
                        guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw fail("\(pattern) isn't a valid regular expression") }
                        rule.title = pattern
                    case "float": rule.floating = true
                    case "tile": rule.floating = false
                    case "maximized": rule.maximized = true
                    case "focused": rule.focused = true
                    case "unfocused": rule.focused = false
                    case "width": rule.width = try fraction(try value(word))
                    case "workspace": rule.workspace = try value(word)
                    case "display": rule.display = try value(word)
                    default: throw fail("unknown rule option \(word)")
                    }
                }
                config.rules.append(rule)
            case "workspace":
                guard let name = args.first, args.count == 1 || args.count == 3 && args[1] == "display" else {
                    throw fail("write workspace <name>, optionally followed by display <name>")
                }
                guard Int(name) == nil else { throw fail("a workspace name can't be a number") }
                if config.workspaces.contains(where: { $0.name == name }) { throw fail("workspace \(name) is declared twice") }
                config.workspaces.append(NamedWorkspace(name: name, display: args.count == 3 ? args[2] : nil))
            case "default-column-display":
                switch try one() {
                case "tabbed": config.defaultColumnDisplayTabbed = true
                case "normal": config.defaultColumnDisplayTabbed = false
                default: throw fail("default-column-display is normal or tabbed")
                }
            case "spawn-at-startup":
                guard !args.isEmpty else { throw fail("spawn-at-startup needs a program") }
                config.startup.append(.spawn(args))
            case "spawn-sh-at-startup":
                guard !args.isEmpty else { throw fail("spawn-sh-at-startup needs a command") }
                config.startup.append(.spawnSh(args.joined(separator: " ")))
            case "empty-workspace-above-first":
                config.emptyWorkspaceAboveFirst = try flag()
            case "bind":
                guard args.count >= 2 else { throw fail("write bind <keys> <command>") }
                guard let keys = combo(args[0], mod: config.mod) else { throw fail("unknown keys \(args[0])") }
                guard let command = Command(args.dropFirst()) else { throw fail("unknown command \(args.dropFirst().joined(separator: " "))") }
                guard bound.insert(keys.combo).inserted else { throw fail("\(args[0]) is bound twice") }
                config.unbind(keys.combo)
                if let shape = keys.shape { config.onMod[shape] = command } else { config.fixed[keys.combo] = command }
            case "unbind":
                let keys = try one()
                if keys == "all" {
                    config.onMod = [:]
                    config.fixed = [:]
                } else {
                    guard let resolved = combo(keys, mod: config.mod) else { throw fail("unknown keys \(keys)") }
                    guard config.unbind(resolved.combo) else { throw fail("\(keys) isn't bound") }
                }
            default:
                throw fail("unknown setting \(name)")
            }
        }
        return config
    }

    @discardableResult
    private mutating func unbind(_ combo: KeyCombo) -> Bool {
        let shapes = onMod.keys.filter { KeyCombo(keyCode: $0.keyCode, mods: $0.mods.under(mod)) == combo }
        for shape in shapes { onMod[shape] = nil }
        return fixed.removeValue(forKey: combo) != nil || !shapes.isEmpty
    }

    public static let defaultsText = """
    # tegi's defaults. tegi rewrites this file on every start, so it always
    # matches the version you run. Don't edit it: copy a line into
    # ~/.config/tegi/config and change it there.

    # LAYOUT

    # Space between windows and around the screen edges, in points.
    gap 16

    # Width of a new column, as a fraction of the screen.
    default-column-width 0.5

    # Where a new window opens: right or left of the focused one, or at the
    # start or end of the strip.
    new-window-position right

    # Space kept clear along the edges of every display, in points:
    # left, right, top, bottom.
    struts 0 0 0 0

    # What switch-preset-column-width and switch-preset-window-height cycle
    # through. Widths can also be fixed, like 1280px.
    preset-column-widths 0.33333 0.5 0.66667
    preset-window-heights 0.33333 0.5 0.66667

    # never: scroll just enough to show the focused column.
    # always: keep the focused column centered.
    # on-overflow: center it when it can't share the screen with the previous one.
    center-focused-column never

    # Uncomment to center a column when it is alone on its workspace.
    # always-center-single-column

    # Uncomment so the key for the workspace you're on goes back to the last one.
    # workspace-auto-back-and-forth

    # Uncomment to keep an empty workspace above the first one too.
    # empty-workspace-above-first

    # New columns show their windows stacked (normal) or as tabs (tabbed).
    default-column-display normal

    # Named workspaces stay even when empty, at the top of their display, and
    # can be reached by name: focus-workspace chat, rule ... workspace chat.
    #   workspace chat
    #   workspace code display LG

    # LOOKS

    # The ring around the focused window; width 0 turns it off. The inactive
    # color marks the focused window on your other displays.
    focus-ring-width 4
    focus-ring-color #7fc8ff
    focus-ring-inactive-color #505050

    # auto fits the ring to each window's own corners; a number uses that
    # radius, in points, for every window.
    window-corner-radius auto

    # The overview shows every workspace at this scale, this far apart, with
    # rounded corners, names and app icons. Behind them goes your wallpaper,
    # softly blurred and dimmed, or backdrop-color. Pushing the pointer into this corner of a
    # display opens it: top-left, top-right, bottom-left, bottom-right or off.
    overview-zoom 0.5
    overview-gap 0.1
    overview-workspace-radius 14
    overview-labels on
    overview-icons on
    overview-backdrop wallpaper
    backdrop-color #262626
    hot-corner top-left

    # The window switcher (next-window) shows window pictures, app icons or both,
    # from everywhere, this display or this workspace, this many points tall,
    # with the picked window's name under them. It waits this many seconds so
    # a quick tap switches without it flashing.
    switcher-shows pictures
    switcher-windows everywhere
    switcher-size 220
    switcher-names on
    switcher-delay 0.15
    switcher-mascot off

    # The hotkey cheat sheet at startup: first-time, always or never.
    hotkey-overlay-at-startup first-time

    # MOTION

    # Off, or with macOS's Reduce Motion, windows jump into place.
    animations on

    # Stretches every animation: 2 is twice as slow, 0.5 twice as fast.
    animation-slowdown 1

    # Each animation is a spring that can be tuned or turned off, for example
    #   animation workspace-switch spring damping-ratio=0.8 stiffness=600
    #   animation window-resize off
    # Damping below 1 bounces. The defaults:
    animation horizontal-view-movement spring damping-ratio=1.0 stiffness=800 epsilon=0.0001
    animation window-movement spring damping-ratio=1.0 stiffness=800 epsilon=0.0001
    animation window-resize spring damping-ratio=1.0 stiffness=800 epsilon=0.0001
    animation workspace-switch spring damping-ratio=1.0 stiffness=1000 epsilon=0.0001
    animation overview-open-close spring damping-ratio=1.0 stiffness=800 epsilon=0.0001

    # Swipe three fingers sideways to scroll the strip, up and down to switch
    # workspaces; four fingers up opens the overview. For this, set System
    # Settings > Trackpad > More Gestures to use four fingers for swiping
    # between apps and spaces.
    three-finger-swipe on

    # Holding this does the same with two fingers or a mouse wheel, and lets
    # you drag windows: left button to move one, right button to resize.
    swipe-modifier alt

    # FOCUS

    # Uncomment so focus follows the pointer. max-scroll-amount limits how far
    # that may scroll the view; 0% never scrolls it.
    # focus-follows-mouse max-scroll-amount 0%

    # Uncomment to move the pointer into windows focused from the keyboard.
    # warp-mouse-to-focus

    # APPS

    # How windows open. rule <bundle-id or *> [title <regex>], then any of:
    # float, tile, width <fraction>, maximized, focused, unfocused,
    # workspace <name>, display <name>. Every matching rule applies, in order.
    # Find an app's bundle id with:  osascript -e 'id of app "Calculator"'
    #   rule com.apple.calculator float
    #   rule com.apple.finder width 0.33333 unfocused
    #   rule com.tinyspeck.slackmacgap workspace chat
    #   rule * title ^Picture-in-Picture$ float

    # Programs to start with tegi.
    #   spawn-at-startup open -a Ghostty

    # DIRECT MODE

    # tegi presents windows through the window server itself: smoother motion,
    # a live overview, and hidden windows gone completely. Needs SIP off; if
    # macOS refuses, windows stay where they are.
    window-server-motion off

    # KEYS
    #
    # Your key moves focus, and with Shift it takes the window along. mod is
    # alt, ctrl+alt, cmd+alt, or a Hyper key: ctrl+alt+cmd, as Raycast,
    # Tinycast and Hyperkey send it, or hyper (⌃⌥⇧⌘) with their Include Shift
    # or Karabiner. A key that already holds Shift uses ⌥⇧ instead. A bound
    # Option+letter no longer types its special character. In your config,
    # bind replaces a binding, unbind <keys> removes one, and unbind all
    # starts from nothing.

    mod alt

    bind mod+shift+slash show-hotkey-overlay
    bind mod+o toggle-overview
    bind mod+q close-window

    # Focus
    bind mod+h focus-column-left
    bind mod+l focus-column-right
    bind mod+j focus-window-down
    bind mod+k focus-window-up
    bind mod+home focus-column-first
    bind mod+end focus-column-last

    # Move
    bind mod+shift+h move-column-left
    bind mod+shift+l move-column-right
    bind mod+shift+j move-window-down
    bind mod+shift+k move-window-up
    bind mod+shift+home move-column-to-first
    bind mod+shift+end move-column-to-last

    # Workspaces
    bind mod+u focus-workspace-down
    bind mod+i focus-workspace-up
    bind mod+shift+u move-column-to-workspace-down
    bind mod+shift+i move-column-to-workspace-up
    # bind alt+ctrl+tab focus-workspace-previous
    bind mod+1 focus-workspace 1
    bind mod+2 focus-workspace 2
    bind mod+3 focus-workspace 3
    bind mod+4 focus-workspace 4
    bind mod+5 focus-workspace 5
    bind mod+6 focus-workspace 6
    bind mod+7 focus-workspace 7
    bind mod+8 focus-workspace 8
    bind mod+9 focus-workspace 9
    bind mod+shift+1 move-column-to-workspace 1
    bind mod+shift+2 move-column-to-workspace 2
    bind mod+shift+3 move-column-to-workspace 3
    bind mod+shift+4 move-column-to-workspace 4
    bind mod+shift+5 move-column-to-workspace 5
    bind mod+shift+6 move-column-to-workspace 6
    bind mod+shift+7 move-column-to-workspace 7
    bind mod+shift+8 move-column-to-workspace 8
    bind mod+shift+9 move-column-to-workspace 9

    # Displays
    bind mod+n focus-monitor-next
    bind mod+p focus-monitor-previous
    bind mod+shift+n move-column-to-monitor-next
    bind mod+shift+p move-column-to-monitor-previous

    # Columns
    bind mod+bracketleft consume-or-expel-window-left
    bind mod+bracketright consume-or-expel-window-right
    bind mod+comma consume-window-into-column
    bind mod+period expel-window-from-column
    bind mod+w toggle-column-tabbed-display

    # Sizes
    bind mod+r switch-preset-column-width
    bind mod+shift+r switch-preset-column-width-back
    bind mod+f maximize-column
    bind mod+shift+f fullscreen-window
    bind mod+e expand-column-to-available-width
    bind mod+c center-column
    bind mod+shift+c center-visible-columns
    bind mod+minus set-column-width -10%
    bind mod+equal set-column-width +10%
    bind mod+shift+minus set-window-height -10%
    bind mod+shift+equal set-window-height +10%

    # Floating
    bind mod+v toggle-window-floating
    bind mod+shift+v switch-focus-between-floating-and-tiling

    # Recent windows: hold Option and press Tab to go back through the windows
    # you used last; ` does the same within the app you're in.
    bind mod+tab next-window
    bind mod+shift+tab previous-window
    bind mod+grave next-window same-app
    bind mod+shift+grave previous-window same-app

    # Launch programs, for example:
    #   bind alt+t spawn open -a Terminal

    """

    public static let starterText = """
    # Your tegi config. Each line here changes one of tegi's defaults; every
    # default, with what it does, is in ~/.config/tegi/defaults. Saved changes
    # apply immediately, and a mistake keeps the last good config while the
    # menu bar says which line is wrong.
    #
    # Things people change first (remove the # to use one):

    # gap 16
    # default-column-width 0.5
    # center-focused-column on-overflow
    # focus-ring-color #7fc8ff
    # animation-slowdown 1
    # swipe-modifier alt

    # bind alt+o toggle-overview
    # unbind alt+q

    """
}

extension KeyCombo {
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, let code = KeyCombo.codes[key] else { return nil }
        var mods: Mods = []
        for p in parts.dropLast() {
            let mod: Mods
            switch p {
            case "cmd", "command": mod = .cmd
            case "alt", "option", "opt": mod = .alt
            case "ctrl", "control": mod = .ctrl
            case "shift": mod = .shift
            case "hyper": mod = .hyper
            case "meh": mod = .meh
            default: return nil
            }
            guard mods.isDisjoint(with: mod) else { return nil }
            mods.formUnion(mod)
        }
        self.init(keyCode: code, mods: mods, key: key, description: text)
    }

    public var symbol: String { symbol(hyper: .hyper) }

    /// As people see it: when `hyper` is one of the two Hyper keys, its modifiers show as one ✦, the way Raycast shows them.
    public func symbol(hyper: Mods) -> String {
        let star = [Mods.hyper, .hyperWithoutShift].contains(hyper) && mods.isSuperset(of: hyper)
        let rest = star ? mods.subtracting(hyper) : mods
        var s = star ? "✦" : ""
        if rest.contains(.ctrl) { s += "⌃" }
        if rest.contains(.alt) { s += "⌥" }
        if rest.contains(.shift) { s += "⇧" }
        if rest.contains(.cmd) { s += "⌘" }
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
                     "pageup": "⇞", "pagedown": "⇟", "tab": "⇥", "return": "↩", "enter": "↩", "space": "Space",
                     "escape": "⎋", "backspace": "⌫", "delete": "⌦", "bracketleft": "[", "bracketright": "]",
                     "comma": ",", "period": ".", "slash": "/", "minus": "-", "equal": "=", "quote": "'",
                     "semicolon": ";", "backslash": "\\", "grave": "`"]
        return s + (names[key] ?? key.uppercased())
    }

    public init?(keyCode: UInt32, mods: Mods) {
        guard let key = KeyCombo.names[keyCode] else { return nil }
        let order: [(Mods, String)] = mods == .hyper ? [(.hyper, "hyper")]
            : mods.isSuperset(of: .meh) ? [(.meh, "meh"), (.cmd, "cmd")]
            : [(.ctrl, "ctrl"), (.alt, "alt"), (.shift, "shift"), (.cmd, "cmd")]
        let text = (order.filter { mods.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
        self.init(keyCode: keyCode, mods: mods, key: key, description: text)
    }

    static let names = Dictionary(canonical.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    static let codes: [String: UInt32] = {
        var c = canonical
        for (char, name) in ["=": "equal", "-": "minus", "]": "bracketright", "[": "bracketleft", "'": "quote",
                             ";": "semicolon", "\\": "backslash", ",": "comma", "/": "slash", ".": "period", "`": "grave"] {
            c[char] = c[name]
        }
        c["enter"] = c["return"]
        return c
    }()

    private static let canonical: [String: UInt32] = {
        let c: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
            "equal": 24, "minus": 27, "bracketright": 30, "bracketleft": 33, "quote": 39,
            "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "period": 47, "grave": 50,
            "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
            "home": 115, "pageup": 116, "delete": 117, "end": 119, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        return c
    }()
}
