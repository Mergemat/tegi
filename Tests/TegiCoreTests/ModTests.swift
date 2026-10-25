import Testing
@testable import TegiCore

@Test func yourKeyMovesEveryDefaultShortcut() throws {
    let c = try Config.parse("mod ctrl+alt")
    #expect(c.binds[KeyCombo("ctrl+alt+h")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("ctrl+alt+shift+h")!] == .moveColumnLeft)
    #expect(c.binds[KeyCombo("alt+h")!] == nil)
    #expect(c.binds.count == Config.builtIn.binds.count)
}

@Test func hyperIsOneKeyAndItsShiftLayerIsOptionShift() throws {
    #expect(KeyCombo("hyper+x")?.mods == [.ctrl, .alt, .shift, .cmd])
    #expect(KeyCombo("meh+x")?.mods == [.ctrl, .alt, .shift])
    #expect(KeyCombo(keyCode: 7, mods: [.ctrl, .alt, .shift, .cmd])?.description == "hyper+x")
    let c = try Config.parse("mod hyper")
    #expect(c.binds[KeyCombo("hyper+h")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("alt+shift+h")!] == .moveColumnLeft)
}

@Test func keysRecordedOnYourKeyFollowItWhenItChanges() throws {
    var text = ConfigEditor.set(["mod"], to: ["hyper"], in: "")
    text = ConfigEditor.bind(.spawn(["open", "-a", "Terminal"]), from: nil, to: KeyCombo("hyper+t"), in: text)
    text = ConfigEditor.bind(.focusColumnLeft, from: KeyCombo("hyper+h"), to: KeyCombo("hyper+a"), in: text)
    text = ConfigEditor.set(["mod"], to: ["cmd+alt"], in: text)
    let c = try Config.parse(text)
    #expect(c.binds[KeyCombo("cmd+alt+t")!] == .spawn(["open", "-a", "Terminal"]))
    #expect(c.binds[KeyCombo("cmd+alt+a")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("cmd+alt+h")!] == nil)
}

@Test func optionIsTheDefaultKeyAndOtherKeysStayPut() throws {
    #expect(!ConfigEditor.set(["mod"], to: ["alt"], in: "").contains("mod"))
    let c = try Config.parse("mod hyper\nbind alt+h toggle-overview")
    #expect(c.binds[KeyCombo("alt+h")!] == .toggleOverview)
    #expect(c.binds[KeyCombo("hyper+h")!] == .focusColumnLeft)
}

@Test func switchingYourKeyCarriesTheShortcutsAlreadyOnIt() throws {
    let text = ConfigEditor.setMod(.hyper, in: "unbind alt+q\nbind alt+t spawn open -a Terminal\nbind cmd+t spawn open -a Safari\n")
    let c = try Config.parse(text)
    #expect(c.mod == .hyper)
    #expect(c.binds[KeyCombo("hyper+q")!] == nil)
    #expect(c.binds[KeyCombo("hyper+t")!] == .spawn(["open", "-a", "Terminal"]))
    #expect(c.binds[KeyCombo("cmd+t")!] == .spawn(["open", "-a", "Safari"]))
}

@Test func aHyperWithoutShiftTakesTheWindowAlongWithShift() throws {
    // Raycast, Tinycast and Hyperkey send ⌃⌥⌘ unless their Include Shift is on.
    let c = try Config.parse("mod ctrl+alt+cmd")
    #expect(c.binds[KeyCombo("ctrl+alt+cmd+h")!] == .focusColumnLeft)
    #expect(c.binds[KeyCombo("hyper+h")!] == .moveColumnLeft)
}

@Test func shortcutsOnAHyperShowItAsOneKey() {
    let plain = Mods([.ctrl, .alt, .cmd])
    #expect(KeyCombo("ctrl+alt+cmd+h")!.symbol(hyper: plain) == "✦H")
    #expect(KeyCombo("hyper+h")!.symbol(hyper: plain) == "✦⇧H")
    #expect(KeyCombo("hyper+h")!.symbol(hyper: .hyper) == "✦H")
    #expect(KeyCombo("ctrl+alt+cmd+h")!.symbol(hyper: .hyper) == "⌃⌥⌘H")
    #expect(KeyCombo("alt+h")!.symbol(hyper: .alt) == "⌥H")
}
