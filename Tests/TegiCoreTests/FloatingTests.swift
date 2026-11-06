import CoreGraphics
import Testing
@testable import TegiCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let small = CGRect(x: 1000, y: 0, width: 500, height: 400)

private func config() -> Config {
    var c = Config()
    c.gap = 10
    return c
}

private func world(screens: [CGRect] = [screen]) -> World {
    World(monitors: screens.enumerated().map { Monitor(id: UInt32($0.offset + 1), screen: $0.element, area: $0.element) })
}

@Test func stripCommandsActOnTheFocusedFloatingWindowNotTheStripBehindIt() {
    let c = config()
    var w = world()
    w.insert(1, config: c)
    w.insert(2, config: c)
    w.addFloating(3, frame: CGRect(x: 300, y: 200, width: 400, height: 300), config: c)
    w.focus(3, config: c)
    let strip = w.monitors[0].workspaces[0].columns
    w.perform(.moveColumnLeft, config: c)
    w.perform(.switchPresetColumnWidth, config: c)
    w.perform(.maximizeColumn, config: c)
    #expect(w.monitors[0].workspaces[0].columns == strip)
    #expect(w.floatingFrame(3) == CGRect(x: 250, y: 200, width: 485, height: 300))
    #expect(w.focusedWindow == 3)
}

@Test func focusMovesBetweenFloatingWindowsByDirection() {
    let c = config()
    var w = world()
    w.insert(1, config: c)
    w.addFloating(2, frame: CGRect(x: 50, y: 300, width: 200, height: 200), config: c)
    w.addFloating(3, frame: CGRect(x: 700, y: 300, width: 200, height: 200), config: c)
    w.addFloating(4, frame: CGRect(x: 400, y: 50, width: 200, height: 200), config: c)
    w.focus(2, config: c)
    w.perform(.focusColumnRight, config: c)
    #expect(w.focusedWindow == 4)
    w.perform(.focusColumnRight, config: c)
    #expect(w.focusedWindow == 3)
    w.perform(.focusColumnFirst, config: c)
    #expect(w.focusedWindow == 2)
    w.perform(.focusColumnLeft, config: c)
    #expect(w.focusedWindow == 2)
    w.focusLayer(floating: false)
    #expect(w.focusedWindow == 1)
}

@Test func floatingWindowsStayReachableOnASmallerDisplayAndComeBackExactly() {
    let c = config()
    var w = world(screens: [screen, small])
    w.insert(1, config: c)
    let frame = CGRect(x: 600, y: 500, width: 350, height: 250)
    w.addFloating(2, frame: frame, config: c)
    w.perform(.moveWorkspaceToMonitor(.right), config: c)
    let there = w.floatingFrame(2)!
    #expect(small.intersection(there).width >= 75 && small.intersection(there).height >= 62)
    w.perform(.moveWorkspaceToMonitor(.left), config: c)
    #expect(w.floatingFrame(2) == frame)
}

@Test func aWindowFloatsAgainWhereItLastFloated() {
    let c = config()
    var w = world()
    w.insert(1, config: c)
    w.float(1, config: c)
    w.setFloatingFrame(1, CGRect(x: 120, y: 80, width: 300, height: 200))
    w.tile(1, config: c)
    #expect(w.locate(1) != nil && w.focusedWindow == 1)
    w.float(1, config: c)
    #expect(w.floatingFrame(1) == CGRect(x: 120, y: 80, width: 300, height: 200))
}

@Test func closingAFocusedDialogReturnsFocusToTheStripNotAnotherFloatingWindow() {
    let c = config()
    var w = world()
    w.insert(1, config: c)
    w.addFloating(2, frame: CGRect(x: 50, y: 50, width: 200, height: 200), config: c)
    w.addFloating(3, frame: CGRect(x: 300, y: 300, width: 200, height: 200), config: c)
    w.focus(3, config: c)
    w.remove(3, forever: true, config: c)
    #expect(w.focusedWindow == 1)
}

@Test func moveFloatingWindowPlacesInTheWorkingAreaOrMovesBy() {
    let c = config()
    var w = world()
    w.addFloating(1, frame: CGRect(x: 300, y: 200, width: 200, height: 100), config: c)
    w.focus(1, config: c)
    w.perform(.moveFloatingWindow(x: .setFixed(100), y: nil), config: c)
    #expect(w.floatingFrame(1) == CGRect(x: 100, y: 200, width: 200, height: 100))
    w.perform(.moveFloatingWindow(x: .adjustFixed(-40), y: .setProportion(0.5)), config: c)
    #expect(w.floatingFrame(1) == CGRect(x: 60, y: 400, width: 200, height: 100))
}

@Test func aRulePositionPlacesAWindowTheFirstTimeItFloatsFromACorner() {
    let c = config()
    var w = world()
    var rule = WindowRule()
    rule.position = FloatingPosition(x: 32, y: 40, anchor: .bottomRight)
    w.addFloating(1, frame: CGRect(x: 0, y: 0, width: 300, height: 200), rule: rule, config: c)
    #expect(w.floatingFrame(1) == CGRect(x: 668, y: 560, width: 300, height: 200))
    w.setFloatingFrame(1, CGRect(x: 10, y: 10, width: 300, height: 200))
    w.tile(1, rule: rule, config: c)
    w.float(1, rule: rule, config: c)
    #expect(w.floatingFrame(1) == CGRect(x: 10, y: 10, width: 300, height: 200))
}
