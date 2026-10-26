import CoreGraphics
import Testing
@testable import TegiCore

@Test func defaultConfigParsesAndBindsEveryCommandOnce() throws {
    let c = Config.builtIn
    #expect(c.gap == 16)
    #expect(try Config.parse(Config.starterText) == c)
    #expect(c.binds[KeyCombo("option+h")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("alt+shift+3")!] == .moveColumnToWorkspace(3))
}

@Test func errorsPointAtTheLine() {
    #expect(throws: ConfigError(line: 2, message: "unknown command focus-sideways")) {
        try Config.parse("gap 4\nbind alt+h focus-sideways")
    }
    #expect(throws: ConfigError(line: 3, message: "option+h is bound twice")) {
        try Config.parse("bind alt+h focus-column-left\n\nbind option+h focus-column-right")
    }
    #expect(throws: ConfigError(line: 1, message: "1.5 is not a fraction between 0 and 1")) {
        try Config.parse("default-column-width 1.5")
    }
}

@Test func commentsAndBlankLinesAreIgnored() throws {
    let c = try Config.parse("# hi\n#gap 3\n\n  gap 0   # tight\nrule com.apple.calculator float\nrule com.apple.finder width 0.25 unfocused\nfocus-ring-color #ff000080 # half red")
    #expect(c.gap == 0)
    #expect(c.rule(app: "com.apple.calculator", title: "").floating == true)
    #expect(c.rule(app: "com.apple.finder", title: "").width == 0.25)
    #expect(c.rule(app: "com.apple.finder", title: "").focused == false)
    #expect(c.binds == Config.builtIn.binds)
    #expect(c.focusRingColor.alpha < 0.51 && c.focusRingColor.red == 1)
}

@Test func malformedKeyCombosAreRejected() {
    for keys in ["alt++h", "+h", "alt+h+", "alt+alt+h", "alt+"] {
        #expect(throws: ConfigError(line: 1, message: "unknown keys \(keys)")) {
            try Config.parse("bind \(keys) focus-column-left")
        }
    }
}

@Test func gapsThatWouldBreakTheLayoutAreRejected() {
    for gap in ["inf", "nan", "-1", "500"] {
        #expect(throws: ConfigError(line: 1, message: "gap must be between 0 and 200 points")) {
            try Config.parse("gap \(gap)")
        }
    }
}

@Test func aSettingWrittenTwiceIsAnError() {
    #expect(throws: ConfigError(line: 2, message: "gap is already set on line 1")) {
        try Config.parse("gap 4\ngap 8")
    }
}

@Test func animationsCanBeTunedOrTurnedOff() throws {
    let c = try Config.parse("""
    animation-slowdown 2
    animation workspace-switch spring damping-ratio=0.8 stiffness=600
    animation window-resize off
    """)
    #expect(c.animations.slowdown == 2)
    #expect(c.animations.spring(.workspaceSwitch) == SpringParams(dampingRatio: 0.8, stiffness: 600, epsilon: 0.0001))
    #expect(c.animations.spring(.windowResize) == nil)
    #expect(c.animations.spring(.horizontalViewMovement) == .view)
    #expect(throws: ConfigError(line: 1, message: "tegi doesn't animate window-open: a new or closing window can't be scaled or faded")) {
        try Config.parse("animation window-open spring stiffness=600")
    }
}

@Test func windowServerMotionIsOptionalAndRejectsUnknownModes() throws {
    #expect(!Config.builtIn.animations.windowServer)
    #expect(try Config.parse("window-server-motion on").animations.windowServer)
    #expect(!(try Config.parse("window-server-motion off")).animations.windowServer)
    #expect(throws: ConfigError(line: 1, message: "window-server-motion is on or off")) {
        try Config.parse("window-server-motion auto")
    }
}

@Test func aConfigWrittenBeforeABindingExistedStillGetsIt() throws {
    let old = try Config.parse("gap 12\nbind alt+h focus-column-left")
    #expect(old.binds[KeyCombo("alt+o")!] == .toggleOverview)
    #expect(old.gap == 12)
}

@Test func yourBindingsReplaceOrRemoveDefaults() throws {
    let c = try Config.parse("bind alt+o focus-column-left\nunbind alt+q")
    #expect(c.binds[KeyCombo("alt+o")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("alt+q")!] == nil)
    #expect(c.binds[KeyCombo("alt+l")!] == .focusColumnRight)
    let bare = try Config.parse("unbind all\nbind ctrl+alt+h focus-column-left")
    #expect(bare.binds.count == 1)
}

@Test func rulesMatchByAppAndTitleAndMergeInOrder() throws {
    let c = try Config.parse("""
    rule * title ^Picture float
    rule org.mozilla.firefox width 0.75 workspace web
    rule org.mozilla.firefox title Picture tile
    workspace web
    """)
    let pip = c.rule(app: "org.mozilla.firefox", title: "Picture-in-Picture")
    #expect(pip.floating == false && pip.width == 0.75 && pip.workspace == "web")
    #expect(c.rule(app: "com.apple.Safari", title: "Picture-in-Picture").floating == true)
    #expect(c.rule(app: "com.apple.Safari", title: "Apple").floating == nil)
    #expect(c.workspaces == [NamedWorkspace(name: "web", display: nil)])
    #expect(throws: ConfigError(line: 1, message: "[ isn't a valid regular expression")) { try Config.parse("rule * title [ float") }
}

@Test func aTileRuleTilesAnAppsWindowsButNotItsMenus() throws {
    let rule = try Config.parse("rule ru.keepcoder.Telegram tile").rule(app: "ru.keepcoder.Telegram", title: "")
    #expect(!rule.floats(tileable: false, popup: false))
    #expect(rule.floats(tileable: false, popup: true))
    #expect(WindowRule().floats(tileable: false, popup: false))
    #expect(!WindowRule().floats(tileable: true, popup: false))
}

@Test func focusGesturesAndStartupSettingsParse() throws {
    let c = try Config.parse("""
    focus-follows-mouse max-scroll-amount 25%
    warp-mouse-to-focus
    three-finger-swipe off
    default-column-display tabbed
    empty-workspace-above-first
    workspace chat display LG
    spawn-at-startup open -a Ghostty
    bind alt+t spawn open -a Terminal
    bind alt+x set-column-display normal
    bind ctrl+alt+tab next-window same-app
    """)
    #expect(c.focusFollowsMouse == 0.25)
    #expect(c.warpMouseToFocus && !c.threeFingerSwipe && c.defaultColumnDisplayTabbed && c.emptyWorkspaceAboveFirst)
    #expect(c.workspaces == [NamedWorkspace(name: "chat", display: "LG")])
    #expect(c.startup == [.spawn(["open", "-a", "Ghostty"])])
    #expect(c.binds[KeyCombo("alt+t")!] == .spawn(["open", "-a", "Terminal"]))
    #expect(c.binds[KeyCombo("alt+x")!] == .setColumnDisplay(tabbed: false))
    #expect(c.binds[KeyCombo("ctrl+alt+tab")!] == .nextWindow(sameApp: true))
    #expect(Config.builtIn.focusFollowsMouse == nil)
    #expect(throws: ConfigError(line: 1, message: "a workspace name can't be a number")) { try Config.parse("workspace 3") }
}

@Test func strutsKeepEdgesClear() throws {
    let c = try Config.parse("struts 10 20 30 40")
    #expect(c.struts.inset(CGRect(x: 0, y: 25, width: 1000, height: 800)) == CGRect(x: 10, y: 55, width: 970, height: 730))
    #expect(throws: ConfigError(line: 1, message: "write struts <left> <right> <top> <bottom> in points")) { try Config.parse("struts 1 2 3") }
}
