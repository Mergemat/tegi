import CoreGraphics
import Testing
@testable import TegiCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let rightScreen = CGRect(x: 1000, y: 0, width: 1000, height: 800)

private func config(_ edit: (inout Config) -> Void = { _ in }) -> Config {
    var c = Config()
    c.gap = 10
    edit(&c)
    return c
}

private func world(_ ids: [WindowID], config: Config, screens: [CGRect] = [screen]) -> World {
    var w = World(monitors: screens.enumerated().map { Monitor(id: UInt32($0.offset + 1), screen: $0.element, area: $0.element) })
    for id in ids { w.insert(id, config: config) }
    return w
}

private extension World {
    func frame(_ id: WindowID, _ c: Config) -> CGRect? { layout(config: c)[id]?.frame }
    func visible(_ id: WindowID, _ c: Config) -> Bool { layout(config: c)[id]?.visible == true }
    var counts: [Int] { monitors[focusedMonitor].workspaces.map(\.columns.count) }
}

@Test func twoHalfColumnsFillTheScreenWithEvenGaps() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.focusColumnLeft, config: c)
    #expect(w.frame(1, c) == CGRect(x: 10, y: 10, width: 485, height: 780))
    #expect(w.frame(2, c) == CGRect(x: 505, y: 10, width: 485, height: 780))
}

@Test func openingAWindowNeverResizesExistingOnes() {
    let c = config()
    var w = world([1, 2], config: c)
    let before = w.layout(config: c)
    w.insert(3, config: c)
    let after = w.layout(config: c)
    #expect(after[1]?.frame.size == before[1]?.frame.size)
    #expect(after[2]?.frame.size == before[2]?.frame.size)
}

@Test func focusingPastTheEdgeScrollsJustEnoughAndParksWhatLeftTheScreen() {
    let c = config()
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnFirst, config: c)
    #expect(w.frame(1, c)?.minX == 10)
    #expect(!w.visible(3, c))

    w.perform(.focusColumnLast, config: c)
    #expect(w.frame(3, c)?.maxX == 990)
    #expect(w.visible(2, c))
    #expect(!w.visible(1, c))
    #expect(w.frame(1, c)?.minX == 999)
}

@Test func aPeekingColumnStaysVisibleUnlessItWouldSpillOntoAnotherDisplay() {
    let c = config { $0.defaultColumnWidth = 0.4 }
    var single = world([1, 2, 3], config: c)
    single.perform(.focusColumnFirst, config: c)
    #expect(single.visible(3, c))

    var dual = world([1, 2, 3], config: c, screens: [screen, rightScreen])
    dual.perform(.focusColumnFirst, config: c)
    let parked = dual.layout(config: c)[3]
    #expect(parked?.visible == false)
    #expect(parked.map { rightScreen.intersects($0.frame) } == false)
}

@Test func closingAWindowFocusesTheNextColumn() {
    let c = config { $0.defaultColumnWidth = 0.3 }
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnLeft, config: c)
    w.remove(2, config: c)
    #expect(w.focusedWindow == 3)
    w.remove(3, config: c)
    #expect(w.focusedWindow == 1)
}

@Test func closingAWindowYouJustOpenedPutsTheViewBack() {
    let c = config { $0.defaultColumnWidth = 0.6 }
    var w = world([1], config: c)
    let before = w.frame(1, c)
    w.insert(2, config: c)
    #expect(w.frame(1, c) != before)
    w.remove(2, config: c)
    #expect(w.focusedWindow == 1)
    #expect(w.frame(1, c) == before)
}

@Test func columnsVanishingOffToTheSideDoNotMoveTheFocusedOne() {
    let c = config()
    var w = world([1, 2], config: c)
    #expect(w.frame(2, c)?.minX == 505)
    w.remove(1, config: c)
    #expect(w.frame(2, c)?.minX == 505)
}

@Test func movingAColumnAwayLeavesTheNextOneShowingOnTheSource() {
    let c = config()
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnLeft, config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    #expect(w.focusedWindow == 2)
    w.perform(.focusWorkspaceUp, config: c)
    #expect(w.focusedWindow == 3)
    #expect(w.visible(3, c))
}

@Test func onOverflowJudgesALongJumpByTheNeighbourBesideTheTarget() {
    let c = config { $0.centerFocusedColumn = .onOverflow; $0.defaultColumnWidth = 0.3 }
    var w = world([1, 2, 3, 4, 5], config: c)
    w.perform(.focusColumnFirst, config: c)
    w.perform(.focusColumnLast, config: c)
    #expect(w.frame(5, c)?.maxX == 990)

    let wide = config { $0.centerFocusedColumn = .onOverflow; $0.defaultColumnWidth = 0.6 }
    var v = world([1], config: wide)
    v.insert(2, config: wide)
    #expect(v.frame(2, wide)?.midX == 500)
}

@Test func alwaysCenterKeepsWideColumnsLeftAligned() {
    let c = config { $0.centerFocusedColumn = .always; $0.defaultColumnWidth = 0.6 }
    var w = world([1], config: c)
    #expect(w.frame(1, c)?.midX == 500)
    w.perform(.setColumnWidth(.setFixed(1200)), config: c)
    #expect(w.frame(1, c)?.minX == 0)
}

@Test func aWindowOpeningUnfocusedLandsBesideWithoutTakingFocusOrScrolling() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.focusColumnLeft, config: c)
    let before = w.frame(1, c)
    var rule = WindowRule()
    rule.focused = false
    w.insert(3, rule: rule, config: c)
    #expect(w.focusedWindow == 1)
    #expect(w.frame(1, c) == before)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1], [3], [2]])
}

@Test func windowsOpenAtLaunchKeepTheirOrderAndTheFirstKeepsFocus() {
    let c = config()
    var w = world([], config: c)
    for id in [1, 2, 3] { w.adopt(id, config: c) }
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1], [2], [3]])
    #expect(w.focusedWindow == 1)
    #expect(w.frame(1, c)?.minX == 10)
}

@Test func consumeAndExpelMoveTheEdgeWindowsAndKeepFocus() {
    let c = config()
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnFirst, config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1, 2, 3]])
    #expect(w.frame(1, c)?.height == 253)
    #expect(w.frame(3, c)?.maxY == 790)

    w.perform(.expelWindowFromColumn, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1, 2], [3]])
    #expect(w.focusedWindow == 1)
}

@Test func consumeOrExpelLeftJoinsAndLeavesTheNeighbour() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1, 2]])
    #expect(w.focusedWindow == 2)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[2], [1]])
    #expect(w.focusedWindow == 2)
}

@Test func presetWidthsCycleEvenWhenTheAppRefusesTheSize() {
    let c = config()
    var w = world([1], config: c)
    let width = { w.monitors[0].workspaces[0].columns[0].width }
    w.perform(.switchPresetColumnWidth, config: c)
    #expect(width() == .proportion(2.0 / 3))
    w.adoptWidth(500, for: 1, config: c)
    w.perform(.switchPresetColumnWidth, config: c)
    #expect(width() == .proportion(2.0 / 3))
    w.perform(.switchPresetColumnWidthBack, config: c)
    #expect(width() == .proportion(0.5))
}

@Test func widthStepsArePercentagePoints() {
    let c = config()
    var w = world([1], config: c)
    w.perform(.setColumnWidth(.adjustProportion(0.1)), config: c)
    #expect(w.monitors[0].workspaces[0].columns[0].width == .proportion(0.6))
    w.perform(.setColumnWidth(.adjustFixed(-100)), config: c)
    #expect(w.frame(1, c)?.width == 484)
}

@Test func maximizeTogglesBackToThePreviousWidth() {
    let c = config()
    var w = world([1], config: c)
    w.perform(.maximizeColumn, config: c)
    #expect(w.frame(1, c)?.width == 980)
    w.perform(.maximizeColumn, config: c)
    #expect(w.frame(1, c)?.width == 485)
}

@Test func expandFillsTheSpaceTheVisibleColumnsLeave() {
    let c = config { $0.defaultColumnWidth = 0.3 }
    var w = world([1, 2], config: c)
    w.perform(.expandColumnToAvailableWidth, config: c)
    #expect(w.frame(1, c)?.minX == 10)
    #expect(w.frame(2, c)?.maxX == 990)
}

@Test func oneWindowHeightIsSetAndTheRestShareWhatIsLeft() {
    let c = config()
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnFirst, config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    w.perform(.setWindowHeight(.setFixed(400)), config: c)
    #expect(w.frame(1, c)?.height == 400)
    let rest: CGFloat = [2, 3].compactMap { w.frame($0, c)?.height }.reduce(0, +)
    #expect(rest == 360)
    w.perform(.resetWindowHeight, config: c)
    #expect(w.frame(3, c)?.maxY == 790)
}

@Test func tabbedColumnsShowOnlyTheActiveWindow() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    w.perform(.toggleColumnTabbedDisplay, config: c)
    #expect(w.visible(2, c))
    #expect(!w.visible(1, c))
    #expect(w.frame(2, c)?.height == 780)
    w.perform(.focusWindowUp, config: c)
    #expect(w.visible(1, c))
    #expect(!w.visible(2, c))
}

@Test func fullscreenCoversTheAreaAndTakesAStackedWindowOutFirst() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    w.perform(.fullscreenWindow, config: c)
    #expect(w.frame(2, c) == screen)
    #expect(!w.visible(1, c))
    w.perform(.fullscreenWindow, config: c)
    #expect(w.frame(2, c)?.width == 485)
}

@Test func workspacesAreDynamicWithOneEmptyAtTheBottom() {
    let c = config()
    var w = world([1, 2], config: c)
    #expect(w.counts == [2, 0])
    w.perform(.moveColumnToWorkspaceDown, config: c)
    #expect(w.counts == [1, 1, 0])
    #expect(w.monitors[0].active == 1)
    w.perform(.focusWorkspaceUp, config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    #expect(w.counts == [2, 0])
    #expect(w.monitors[0].active == 0)
}

@Test func anEmptiedWorkspaceStaysUntilYouLeaveIt() {
    let c = config()
    var w = world([1, 2], config: c)
    w.remove(1, config: c)
    w.remove(2, config: c)
    #expect(w.counts == [0, 0])
    #expect(w.focusedWindow == nil)
    w.perform(.focusWorkspaceDown, config: c)
    #expect(w.counts == [0])
}

@Test func previousWorkspaceSurvivesCleanup() {
    let c = config { $0.workspaceAutoBackAndForth = true }
    var w = world([1], config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    w.insert(2, config: c)
    w.perform(.focusWorkspace(2), config: c)
    w.perform(.focusWorkspace(1), config: c)
    #expect(w.focusedWindow == 1 || w.focusedWindow == 2)
    w.perform(.focusWorkspace(2), config: c)
    w.perform(.focusWorkspace(2), config: c)
    #expect(w.monitors[0].active == 0)
}

@Test func focusWindowOrWorkspaceFallsThroughAtTheBottom() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    w.perform(.focusWorkspaceUp, config: c)
    w.perform(.focusWindowOrWorkspaceDown, config: c)
    #expect(w.focusedWindow == 2)
}

@Test func columnsMoveToTheDisplayInThatDirection() {
    let c = config()
    var w = world([1, 2], config: c, screens: [screen, rightScreen])
    w.perform(.moveColumnRightOrToMonitorRight, config: c)
    #expect(w.focusedMonitor == 1)
    #expect(w.locate(2)?.monitor == 1)
    #expect(w.frame(2, c)?.minX == 1010)
    w.perform(.focusColumnOrMonitorLeft, config: c)
    #expect(w.focusedMonitor == 0)
    #expect(w.focusedWindow == 1)
}

@Test func unpluggedWorkspacesComeHomeWhenTheDisplayReturns() {
    let c = config()
    var w = world([], config: c, screens: [screen, rightScreen])
    w.insert(1, monitor: 1, config: c)
    w.setDisplays([Display(id: 1, screen: screen, area: screen)], config: c)
    #expect(w.monitors.count == 1)
    #expect(w.locate(1)?.monitor == 0)
    #expect(w.focusedWindow == nil)

    w.setDisplays([Display(id: 1, screen: screen, area: screen), Display(id: 2, screen: rightScreen, area: rightScreen)], config: c)
    #expect(w.locate(1)?.monitor == 1)
    #expect(w.monitors[0].workspaces.count == 1)
}

@Test(arguments: 0..<40)
func randomOperationsKeepTheLayoutValid(seed: UInt64) {
    var rng = SplitMix(seed: seed)
    let c = config { $0.centerFocusedColumn = [.never, .always, .onOverflow][Int(seed % 3)] }
    var w = world([], config: c, screens: [screen, rightScreen])
    var alive: [WindowID] = []
    var next = 1
    let commands: [Command] = [
        .focusColumnLeft, .focusColumnRight, .focusWindowUp, .focusWindowDown, .focusWorkspaceUp, .focusWorkspaceDown,
        .moveColumnLeft, .moveColumnRight, .moveWindowUp, .moveWindowDown, .moveColumnToWorkspaceDown,
        .moveColumnToWorkspaceUp, .moveWindowToWorkspaceDown, .consumeWindowIntoColumn, .expelWindowFromColumn,
        .consumeOrExpelWindowLeft, .consumeOrExpelWindowRight, .switchPresetColumnWidth, .maximizeColumn,
        .fullscreenWindow, .toggleColumnTabbedDisplay, .centerColumn, .expandColumnToAvailableWidth,
        .setWindowHeight(.adjustProportion(0.1)), .focusMonitor(.right), .focusMonitor(.left),
        .moveColumnToMonitor(.right), .moveWorkspaceDown, .focusWorkspacePrevious, .moveWorkspaceToMonitor(.left),
    ]
    for _ in 0..<300 {
        switch rng.next() % 4 {
        case 0:
            w.insert(next, config: c)
            alive.append(next)
            next += 1
        case 1 where !alive.isEmpty:
            let id = alive.remove(at: Int(rng.next() % UInt64(alive.count)))
            w.remove(id, config: c)
        default:
            w.perform(commands[Int(rng.next() % UInt64(commands.count))], config: c)
        }

        let placements = w.layout(config: c)
        #expect(Set(placements.keys) == Set(alive))
        for (mi, mon) in w.monitors.enumerated() {
            #expect(mon.workspaces.last?.isEmpty == true)
            #expect(mon.workspaces.indices.contains(mon.active))
            for (wi, ws) in mon.workspaces.enumerated() {
                #expect(!ws.isEmpty || wi == mon.active || wi == mon.workspaces.count - 1)
                #expect(ws.isEmpty || ws.columns.indices.contains(ws.active))
                for col in ws.columns {
                    #expect(!col.tiles.isEmpty)
                    #expect(col.tiles.indices.contains(col.active))
                }
            }
            for id in alive where w.locate(id)?.monitor == mi {
                guard let p = placements[id] else { continue }
                #expect(p.frame.width >= 1 && p.frame.height >= 1)
                if p.visible {
                    #expect(w.monitors.indices.allSatisfy { $0 == mi || !w.monitors[$0].screen.intersects(p.frame) })
                }
            }
        }
        if let f = w.focusedWindow { #expect(alive.contains(f)) }
        if alive.isEmpty { #expect(w.focusedWindow == nil) }
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test func droppingAWindowInAGapPutsItThere() {
    let c = config { $0.defaultColumnWidth = 0.3 }
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnFirst, config: c)
    let between2and3 = w.layout(config: c)[3]!.frame.minX - 5
    let pos = w.insertPosition(monitor: 0, workspace: 0, at: CGPoint(x: between2and3, y: 400), config: c)
    #expect(pos == .newColumn(2))
    w.move(1, to: 0, workspace: 0, at: pos, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[2], [1], [3]])
    #expect(w.focusedWindow == 1)

    let underTop = w.layout(config: c)[3]!.frame
    let pos2 = w.insertPosition(monitor: 0, workspace: 0, at: CGPoint(x: underTop.midX, y: underTop.maxY), config: c)
    #expect(pos2 == .inColumn(2, tile: 1))
    w.move(2, to: 0, workspace: 0, at: pos2, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1], [3, 2]])
}

@Test func aWorkspaceHoldingOnlyFloatingWindowsIsKept() {
    let c = config()
    var w = world([1], config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    let first = w.monitors[0].workspaces[0].id
    w.pinned = [first]
    w.perform(.focusWorkspaceUp, config: c)
    w.perform(.focusWorkspaceDown, config: c)
    #expect(w.find(workspace: first) != nil)
}

@Test func namedWorkspacesStayAndCanBeReachedByName() {
    let c = config()
    var w = world([1], config: c)
    w.nameWorkspaces([NamedWorkspace(name: "chat", display: nil)])
    #expect(w.monitors[0].workspaces.first?.name == "chat")
    w.perform(.focusWorkspace(.name("chat")), config: c)
    #expect(w.focusedWindow == nil)
    w.perform(.focusWorkspaceDown, config: c)
    #expect(w.monitors[0].workspaces.first?.name == "chat")
    var rule = WindowRule()
    rule.workspace = "chat"
    w.insert(2, rule: rule, config: c)
    #expect(w.locate(2)?.workspace == 0)
    #expect(w.focusedWindow == 1)
}

@Test func swappingTradesWindowsBetweenColumns() {
    let c = config()
    var w = world([1, 2, 3], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    w.perform(.focusColumnLeft, config: c)
    w.perform(.swapWindowRight, config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[2], [1, 3]] || w.monitors[0].workspaces[0].columns.map(\.windows) == [[3], [2, 1]])
    #expect(w.focusedWindow == 1)
}

@Test func wrappingAndDirectFocusCommands() {
    let c = config { $0.defaultColumnWidth = 0.3 }
    var w = world([1, 2, 3], config: c)
    w.perform(.focusColumnRightOrFirst, config: c)
    #expect(w.focusedWindow == 1)
    w.perform(.focusColumnLeftOrLast, config: c)
    #expect(w.focusedWindow == 3)
    w.perform(.focusColumn(2), config: c)
    #expect(w.focusedWindow == 2)
    w.perform(.moveColumnToIndex(1), config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[2], [1], [3]])
    w.perform(.consumeWindowIntoColumn, config: c)
    w.perform(.focusWindowDownOrTop, config: c)
    #expect(w.focusedWindow == 1)
    w.perform(.focusWindowDownOrTop, config: c)
    #expect(w.focusedWindow == 2)
}

@Test func anEmptyWorkspaceCanSitAboveTheFirst() {
    let c = config()
    var w = World(monitors: [Monitor(id: 1, screen: CGRect(x: 0, y: 0, width: 1000, height: 800), area: CGRect(x: 0, y: 0, width: 1000, height: 800))])
    w.emptyWorkspaceAboveFirst = true
    w.insert(1, config: c)
    w.perform(.focusWorkspaceDown, config: c)
    w.perform(.focusWorkspaceUp, config: c)
    #expect(w.monitors[0].workspaces.map(\.columns.count) == [0, 1, 0])
    #expect(w.focusedWindow == 1)
}

@Test func droppingALoneWindowOntoItselfLeavesItAlone() {
    let c = config()
    var w = world([1, 2], config: c)
    w.move(1, to: 0, workspace: 0, at: .inColumn(0, tile: 0), config: c)
    #expect(w.monitors[0].workspaces[0].columns.map(\.windows) == [[1], [2]])
}

@Test func stackedFixedHeightsNeverRunPastTheScreen() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.setWindowHeight(.setFixed(600)), config: c)
    w.perform(.focusColumnLeft, config: c)
    w.perform(.setWindowHeight(.setFixed(600)), config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    let bottom = [1, 2].compactMap { w.frame($0, c)?.maxY }.max()!
    #expect(bottom <= 790)
}

@Test(arguments: [1, 2]) func aRefusedHeightLeavesRoomForItsStackedNeighbour(id: WindowID) throws {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    let asked = try #require(w.frame(id, c)).size
    _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: id)
    let top = try #require(w.frame(1, c)), bottom = try #require(w.frame(2, c))
    #expect(w.frame(id, c)?.height == 500)
    #expect(bottom.minY - top.maxY == CGFloat(c.gap))
    #expect(top.minY == 10)
    #expect(bottom.maxY == 790)
    let preview = w.stripFrames(monitor: 0, workspace: 0, config: c)
    #expect(preview.first { $0.id == id }?.frame.height == 500)
}

@Test func anOverfullStackRevealsTheFocusedWindowWithoutOverlapping() throws {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    for id in 1...2 {
        let asked = try #require(w.frame(id, c)).size
        _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: id)
    }
    for id in [1, 2, 1] {
        w.focus(id, config: c)
        let active = try #require(w.frame(id, c))
        #expect(active.minY >= 10)
        #expect(active.maxY <= 790)
        let frames = w.layout(config: c)
        #expect(frames[1]?.strip?.maxY == frames[2]!.strip!.minY - CGFloat(c.gap))
    }
}

@Test func anExplicitHeightCannotTakeSpaceReservedByItsNeighbour() throws {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    w.focus(1, config: c)
    w.perform(.setWindowHeight(.setFixed(600)), config: c)
    let asked = try #require(w.frame(2, c)).size
    _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: 2)
    #expect(w.frame(1, c)?.height == 270)
    #expect(w.frame(2, c)?.height == 500)
    #expect(w.frame(2, c)?.maxY == 790)
}

@Test func learnedHeightsFollowTheWindowAndCanBeRelearned() throws {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    let asked = try #require(w.frame(1, c)).size
    _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: 1)
    w.perform(.expelWindowFromColumn, config: c)
    w.perform(.consumeWindowIntoColumn, config: c)
    #expect(w.frame(1, c)?.height == 500)
    w.focus(1, config: c)
    w.perform(.resetWindowHeight, config: c)
    #expect(w.frame(1, c)?.height == asked.height)
    _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: 1)
    _ = w.observeSize(CGSize(width: asked.width, height: 300), asked: asked, for: 1)
    #expect(w.frame(1, c)?.height == asked.height)
    _ = w.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: 1)
    w.perform(.setColumnWidth(.setFixed(600)), config: c)
    #expect(w.frame(1, c)?.height == asked.height)
    w.remove(1, config: c)
    w.insert(1, config: c)
    w.perform(.consumeOrExpelWindowLeft, config: c)
    #expect(w.frame(1, c)?.height == asked.height)
}

@Test func droppingBetweenWorkspacesMakesANewOne() {
    let c = config()
    var w = world([1, 2], config: c)
    w.perform(.moveColumnToWorkspaceDown, config: c)
    #expect(w.counts == [1, 1, 0])
    w.moveToNewWorkspace(2, monitor: 0, at: 1, config: c)
    #expect(w.counts == [1, 1, 0])
    #expect(w.locate(2)?.workspace == 1)
    #expect(w.focusedWindow == 2)
    w.moveToNewWorkspace(1, monitor: 0, at: 0, config: c)
    #expect(w.monitors[0].workspaces.first?.columns.first?.windows == [1])
    #expect(w.monitors[0].workspaces.allSatisfy { !$0.isEmpty } == false)
}

@Test func presetWidthsCanBeFixed() throws {
    var c = try Config.parse("preset-column-widths 0.5 1200px")
    c.gap = 10
    var w = world([1], config: c)
    w.perform(.switchPresetColumnWidth, config: c)
    #expect(w.frame(1, c)?.width == 1200)
    w.perform(.switchPresetColumnWidth, config: c)
    #expect(w.frame(1, c)?.width == 485)
}

@Test func droppingAWindowBackInItsOwnPlaceMovesNothing() {
    let c = config { $0.defaultColumnWidth = 0.5 }
    var w = world([1, 2, 3], config: c)
    w.focus(2, config: c)
    let before = w.layout(config: c)
    for edge in [1, 2] {
        w.move(2, to: 0, workspace: 0, at: .newColumn(edge), config: c)
        #expect(w.layout(config: c) == before)
    }
}

@Test func newWindowsOpenWhereYouSay() throws {
    let order: [NewWindowPosition: [WindowID]] = [.right: [1, 2, 4, 3], .left: [1, 4, 2, 3], .start: [4, 1, 2, 3], .end: [1, 2, 3, 4]]
    for (position, expected) in order {
        var w = world([1, 2, 3], config: config())
        w.perform(.focusColumnLeft, config: config())
        w.insert(4, config: config { $0.newWindowPosition = position })
        let ws = w.monitors[0].workspaces[w.monitors[0].active]
        #expect(ws.columns.map(\.activeWindow) == expected, "\(position)")
        #expect(ws.activeWindow == 4, "\(position) focuses the new window")
    }
    #expect(try Config.parse("new-window-position end").newWindowPosition == .end)
    #expect(Config.builtIn.newWindowPosition == .right)
}
