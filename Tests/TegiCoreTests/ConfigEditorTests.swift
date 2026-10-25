import Testing
@testable import TegiCore

private let mine = """
# my setup
gap 24

# looks
focus-ring-color #ff0000
# window-corner-radius 8
bind alt+t spawn open -a Terminal

"""

private func parsed(_ text: String) -> Config { try! Config.parse(text) }

@Test func changingASettingRewritesItsLineAndNothingElse() {
    let text = ConfigEditor.set(["gap"], to: ["8"], in: mine)
    #expect(text == mine.replacingOccurrences(of: "gap 24", with: "gap 8"))
}

@Test func aNewSettingGoesAtTheEnd() {
    let text = ConfigEditor.set(["window-corner-radius"], to: ["20"], in: mine)
    #expect(text == mine + "window-corner-radius 20\n")
    #expect(parsed(text).windowCornerRadius == 20)
}

@Test func settingTheDefaultValueRemovesTheLine() {
    let text = ConfigEditor.set(["gap"], to: ["16"], in: mine)
    #expect(!text.contains("gap"))
    #expect(text.contains("# window-corner-radius 8"))
    #expect(parsed(text) == parsed(mine.replacingOccurrences(of: "gap 24\n", with: "")))
}

@Test func animationsAreSetOneByOne() {
    var text = ConfigEditor.set(["animation", "workspace-switch"], to: ["spring", "damping-ratio=0.8", "stiffness=600"], in: mine)
    text = ConfigEditor.set(["animation", "window-resize"], to: ["off"], in: text)
    let config = parsed(text)
    #expect(config.animations.springs[.workspaceSwitch]?.dampingRatio == 0.8)
    #expect(config.animations.springs[.windowResize] == nil)
    #expect(config.animations.springs[.windowMovement] == Config.builtIn.animations.springs[.windowMovement])
}

@Test func listsAreReplacedWhole() {
    var text = ConfigEditor.setList("rule", to: [["com.apple.calculator", "float"], ["*", "title", "^PiP$", "float"]], in: mine)
    #expect(parsed(text).rules.count == 2)
    text = ConfigEditor.setList("rule", to: [["com.apple.finder", "width", "0.5"]], in: text)
    #expect(parsed(text).rules.map(\.app) == ["com.apple.finder"])
    #expect(ConfigEditor.setList("rule", to: [], in: text) == mine)
}

@Test func movingAShortcutUnbindsTheOldKeys() {
    let text = ConfigEditor.bind(.focusColumnLeft, from: KeyCombo("alt+h"), to: KeyCombo("alt+a"), in: mine)
    let binds = parsed(text).binds
    #expect(binds[KeyCombo("alt+a")!] == .focusColumnLeft)
    #expect(binds[KeyCombo("alt+h")!] == nil)
    #expect(binds[KeyCombo("alt+t")!] == .spawn(["open", "-a", "Terminal"]))
}

@Test func movingAShortcutBackToItsDefaultLeavesNoTrace() {
    let moved = ConfigEditor.bind(.focusColumnLeft, from: KeyCombo("alt+h"), to: KeyCombo("alt+a"), in: mine)
    #expect(ConfigEditor.bind(.focusColumnLeft, from: KeyCombo("alt+a"), to: KeyCombo("option+h"), in: moved) == mine)
}

@Test func removingAShortcutOnlyTouchesThatShortcut() {
    let text = ConfigEditor.bind(.closeWindow, from: KeyCombo("alt+q"), to: nil, in: mine)
    #expect(parsed(text).binds[KeyCombo("alt+q")!] == nil)
    #expect(parsed(text).binds.count == Config.builtIn.binds.count)
    #expect(ConfigEditor.bind(.spawn(["open", "-a", "Terminal"]), from: KeyCombo("alt+t"), to: nil, in: mine) == mine.replacingOccurrences(of: "\nbind alt+t spawn open -a Terminal", with: ""))
}

@Test func takingKeysFromAnotherCommandReplacesIt() {
    let text = ConfigEditor.bind(.toggleOverview, from: nil, to: KeyCombo("alt+q"), in: mine)
    #expect(parsed(text).binds[KeyCombo("alt+q")!] == .toggleOverview)
}

@Test func everyCommandWritesBackAsWhatItReads() {
    var commands = Array(Command.simple.values) + Config.builtIn.binds.values
    commands += [.focusWorkspace(.name("chat")), .setColumnWidth(.setFixed(800)), .setWindowHeight(.adjustProportion(-0.1)),
                 .focusMonitor(.left), .moveWorkspaceToIndex(2), .setColumnDisplay(tabbed: true), .spawnSh("echo hi"),
                 .previousWindow(sameApp: true), .focusWindowInColumn(3)]
    for command in commands { #expect(Command(command.words) == command, "\(command)") }
}

@Test func recordedKeysMatchTheirWrittenForm() {
    #expect(KeyCombo(keyCode: 4, mods: [.alt, .shift]) == KeyCombo("alt+shift+h"))
    #expect(KeyCombo(keyCode: 4, mods: [.alt, .shift])?.description == "alt+shift+h")
    #expect(KeyCombo(keyCode: 33, mods: [.cmd])?.description == "cmd+bracketleft")
    #expect(KeyCombo(keyCode: 999, mods: []) == nil)
}

@Test func rulesAndWorkspacesWriteBackAsWhatTheyRead() throws {
    let text = """
    rule com.apple.calculator float
    rule * title ^Picture-in-Picture$ tile width 0.4 maximized unfocused workspace chat display LG
    workspace chat
    workspace code display LG
    """
    let config = try Config.parse(text)
    var rebuilt = ConfigEditor.setList("rule", to: config.rules.map(\.words), in: "")
    rebuilt = ConfigEditor.setList("workspace", to: config.workspaces.map(\.words), in: rebuilt)
    let again = try Config.parse(rebuilt)
    #expect(again.rules == config.rules)
    #expect(again.workspaces == config.workspaces)
}

@Test func settingsCanOpenOnAPane() {
    #expect(Command(["show-settings"]) == .showSettings(nil))
    #expect(Command(["show-settings", "hotkeys"]) == .showSettings("hotkeys"))
    #expect(Command(Command.showSettings("motion").words) == .showSettings("motion"))
}

@Test func cornersFollowEachWindowUnlessANumberIsGiven() throws {
    #expect(Config.builtIn.windowCornerRadius == nil)
    #expect(try Config.parse("window-corner-radius auto").windowCornerRadius == nil)
    #expect(try Config.parse("window-corner-radius 10").windowCornerRadius == 10)
}
