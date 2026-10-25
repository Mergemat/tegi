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
    public var slowdown = 1.0
    public var springs: [Name: SpringParams] = [
        .horizontalViewMovement: .view, .windowMovement: .view, .windowResize: .view,
        .workspaceSwitch: .workspace, .overviewOpenClose: .view,
    ]

    public func spring(_ name: Name) -> SpringParams? { on ? springs[name] : nil }
}

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
    public var hotCorner = true
    public var threeFingerSwipe = true
    public var focusFollowsMouse: Double?
    public var warpMouseToFocus = false
    public var backdropColor = Color(hex: "#262626")!
    public var focusRingWidth: Double = 4
    public var focusRingColor = Color(hex: "#7fc8ff")!
    public var focusRingInactiveColor = Color(hex: "#505050")!
    public var windowCornerRadius: Double = 12
    public var rules: [WindowRule] = []
    public var workspaces: [NamedWorkspace] = []
    public var defaultColumnDisplayTabbed = false
    public var emptyWorkspaceAboveFirst = false
    public var startup: [Command] = []

    public func rule(app: String?, title: String) -> WindowRule {
        var merged = WindowRule()
        for r in rules where r.matches(app: app, title: title) { merged.merge(r) }
        return merged
    }
    public var binds: [KeyCombo: Command] = [:]

    public init() {}

    public static let builtIn = try! parse(defaultsText, over: Config())

    public static func parse(_ text: String, over base: Config = builtIn) throws(ConfigError) -> Config {
        var config = base
        var seen: [String: Int] = [:]
        var bound: Set<KeyCombo> = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
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
                config.windowCornerRadius = try number(0...40, "window-corner-radius must be between 0 and 40 points")
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
            case "swipe-modifier":
                let v = try one()
                if v == "off" {
                    config.swipeModifier = []
                } else {
                    guard let combo = KeyCombo(v + "+a"), !combo.mods.isEmpty else { throw fail("swipe-modifier is alt, ctrl, cmd, shift, a combination like alt+shift, or off") }
                    config.swipeModifier = combo.mods
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
                switch try one() {
                case "on": config.hotCorner = true
                case "off": config.hotCorner = false
                default: throw fail("hot-corner is on or off")
                }
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
                guard let combo = KeyCombo(args[0]) else { throw fail("unknown keys \(args[0])") }
                guard let command = Command(args.dropFirst()) else { throw fail("unknown command \(args.dropFirst().joined(separator: " "))") }
                guard bound.insert(combo).inserted else { throw fail("\(args[0]) is bound twice") }
                config.binds[combo] = command
            case "unbind":
                let keys = try one()
                if keys == "all" {
                    config.binds = [:]
                } else {
                    guard let combo = KeyCombo(keys) else { throw fail("unknown keys \(keys)") }
                    guard config.binds.removeValue(forKey: combo) != nil else { throw fail("\(keys) isn't bound") }
                }
            default:
                throw fail("unknown setting \(name)")
            }
        }
        return config
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
    window-corner-radius 12

    # The overview shows every workspace at this scale, on this backdrop.
    # Pushing the pointer into the top-left corner of a display opens it.
    overview-zoom 0.5
    backdrop-color #262626
    hot-corner on

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

    # KEYS
    #
    # Option moves focus, Option+Shift moves things. A bound Option+letter no
    # longer types its special character. In your config, bind replaces a
    # binding, unbind <keys> removes one, and unbind all starts from nothing.

    bind alt+shift+slash show-hotkey-overlay
    bind alt+o toggle-overview
    bind alt+q close-window

    # Focus
    bind alt+h focus-column-left
    bind alt+l focus-column-right
    bind alt+j focus-window-down
    bind alt+k focus-window-up
    bind alt+home focus-column-first
    bind alt+end focus-column-last

    # Move
    bind alt+shift+h move-column-left
    bind alt+shift+l move-column-right
    bind alt+shift+j move-window-down
    bind alt+shift+k move-window-up
    bind alt+shift+home move-column-to-first
    bind alt+shift+end move-column-to-last

    # Workspaces
    bind alt+u focus-workspace-down
    bind alt+i focus-workspace-up
    bind alt+shift+u move-column-to-workspace-down
    bind alt+shift+i move-column-to-workspace-up
    # bind alt+ctrl+tab focus-workspace-previous
    bind alt+1 focus-workspace 1
    bind alt+2 focus-workspace 2
    bind alt+3 focus-workspace 3
    bind alt+4 focus-workspace 4
    bind alt+5 focus-workspace 5
    bind alt+6 focus-workspace 6
    bind alt+7 focus-workspace 7
    bind alt+8 focus-workspace 8
    bind alt+9 focus-workspace 9
    bind alt+shift+1 move-column-to-workspace 1
    bind alt+shift+2 move-column-to-workspace 2
    bind alt+shift+3 move-column-to-workspace 3
    bind alt+shift+4 move-column-to-workspace 4
    bind alt+shift+5 move-column-to-workspace 5
    bind alt+shift+6 move-column-to-workspace 6
    bind alt+shift+7 move-column-to-workspace 7
    bind alt+shift+8 move-column-to-workspace 8
    bind alt+shift+9 move-column-to-workspace 9

    # Displays
    bind alt+n focus-monitor-next
    bind alt+p focus-monitor-previous
    bind alt+shift+n move-column-to-monitor-next
    bind alt+shift+p move-column-to-monitor-previous

    # Columns
    bind alt+bracketleft consume-or-expel-window-left
    bind alt+bracketright consume-or-expel-window-right
    bind alt+comma consume-window-into-column
    bind alt+period expel-window-from-column
    bind alt+w toggle-column-tabbed-display

    # Sizes
    bind alt+r switch-preset-column-width
    bind alt+shift+r switch-preset-column-width-back
    bind alt+f maximize-column
    bind alt+shift+f fullscreen-window
    bind alt+e expand-column-to-available-width
    bind alt+c center-column
    bind alt+shift+c center-visible-columns
    bind alt+minus set-column-width -10%
    bind alt+equal set-column-width +10%
    bind alt+shift+minus set-window-height -10%
    bind alt+shift+equal set-window-height +10%

    # Floating
    bind alt+v toggle-window-floating
    bind alt+shift+v switch-focus-between-floating-and-tiling

    # Recent windows: hold Option and press Tab to go back through the windows
    # you used last; ` does the same within the app you're in.
    bind alt+tab next-window
    bind alt+shift+tab previous-window
    bind alt+grave next-window same-app
    bind alt+shift+grave previous-window same-app

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
    init?(_ text: String) {
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
            default: return nil
            }
            guard !mods.contains(mod) else { return nil }
            mods.insert(mod)
        }
        self.init(keyCode: code, mods: mods, key: key, description: text)
    }

    public var symbol: String {
        var s = ""
        if mods.contains(.ctrl) { s += "⌃" }
        if mods.contains(.alt) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.cmd) { s += "⌘" }
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
                     "pageup": "⇞", "pagedown": "⇟", "tab": "⇥", "return": "↩", "enter": "↩", "space": "Space",
                     "escape": "⎋", "backspace": "⌫", "delete": "⌦", "bracketleft": "[", "bracketright": "]",
                     "comma": ",", "period": ".", "slash": "/", "minus": "-", "equal": "=", "quote": "'",
                     "semicolon": ";", "backslash": "\\", "grave": "`"]
        return s + (names[key] ?? key.uppercased())
    }

    static let codes: [String: UInt32] = {
        var c: [String: UInt32] = [
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
        for (char, name) in ["=": "equal", "-": "minus", "]": "bracketright", "[": "bracketleft", "'": "quote",
                             ";": "semicolon", "\\": "backslash", ",": "comma", "/": "slash", ".": "period", "`": "grave"] {
            c[char] = c[name]
        }
        c["enter"] = c["return"]
        return c
    }()
}
