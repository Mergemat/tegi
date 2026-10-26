import CoreGraphics
import Testing
@testable import TegiCore

private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

private func strip(_ n: Int, width: Double = 0.5) -> (World, Config) {
    var c = Config()
    c.gap = 10
    c.defaultColumnWidth = width
    var w = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...n { w.insert(id, config: c) }
    w.perform(.focusColumnFirst, config: c)
    return (w, c)
}

@Test func aFinishedCoastSettlesOnTheNearestColumnEdge() {
    var (w, c) = strip(4)
    w.scrollView(monitor: 0, to: 900, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == 900)
    w.endSwipe(monitor: 0, coastingTo: 900, config: c)
    #expect(w.layout(config: c)[4]?.frame.maxX == 990)
    #expect(w.viewPosition(monitor: 0, config: c) == 980)
}

@Test func aGentleDragSettlesBackToItsColumn() {
    var (w, c) = strip(3)
    let start = w.viewPosition(monitor: 0, config: c)
    w.scrollView(monitor: 0, to: start + 60, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == start + 60)
    w.endSwipe(monitor: 0, coastingTo: start + 60, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == start)
}

@Test func centeredColumnsSettleOnTheNearestCenter() {
    var (w, c) = strip(4)
    c.centerFocusedColumn = .always
    w.scrollView(monitor: 0, to: 200, config: c)
    w.endSwipe(monitor: 0, coastingTo: 200, config: c)
    #expect(abs(w.layout(config: c)[2]!.frame.midX - screen.midX) <= 0.5)
    #expect(w.focusedWindow == 2)
}

@Test func narrowColumnsCanSettleAgainstTheRightEdge() {
    var (w, c) = strip(6, width: 0.3)
    w.scrollView(monitor: 0, to: 160, config: c)
    w.endSwipe(monitor: 0, coastingTo: 160, config: c)
    #expect(w.layout(config: c)[4]?.frame.maxX == 990)
    #expect(w.viewPosition(monitor: 0, config: c) == 188)
}

@Test func releasingAShortStripDoesNotMoveItToTheOtherEdge() {
    var (w, c) = strip(1)
    let start = w.viewPosition(monitor: 0, config: c)
    w.scrollView(monitor: 0, to: start + 200, config: c)
    w.endSwipe(monitor: 0, coastingTo: start + 200, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == start)
}

@Test func aSwipeNeverSnapsPastTheEnds() {
    var (w, c) = strip(3)
    w.scrollView(monitor: 0, to: -900, config: c)
    w.endSwipe(monitor: 0, coastingTo: -5000, config: c)
    #expect(w.layout(config: c)[1]?.frame.minX == 10)
    w.endSwipe(monitor: 0, coastingTo: 50_000, config: c)
    #expect(w.layout(config: c)[3]?.frame.maxX == 990)
    #expect(w.focusedWindow == 3)
}

@Test func pullingPastAnEndKeepsTheStripWithinReach() {
    var (w, c) = strip(3)
    let start = w.viewPosition(monitor: 0, config: c)
    w.scrollView(monitor: 0, to: start - 5000, config: c)
    let pulled = w.viewPosition(monitor: 0, config: c)
    #expect(pulled < start && pulled > start - 100)
    w.endSwipe(monitor: 0, coastingTo: pulled, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == start)
}

@Test func reversingAnEdgePullReturnsToTheSamePosition() {
    var (w, c) = strip(3)
    let start = w.viewPosition(monitor: 0, config: c)
    for offset in [-50.0, -200, -50, 0] {
        w.scrollView(monitor: 0, to: start + offset, config: c)
    }
    #expect(w.viewPosition(monitor: 0, config: c) == start)
}

@Test func keyboardFocusStillRevealsAColumnAfterFreeScrolling() {
    var (w, c) = strip(4)
    w.scrollView(monitor: 0, to: 200, config: c)
    w.endSwipe(monitor: 0, coastingTo: 200, config: c)
    w.perform(.focusColumnLast, config: c)
    let frame = w.layout(config: c)[4]!.frame
    #expect(w.focusedWindow == 4)
    #expect(frame.minX >= 0 && frame.maxX <= screen.width)
}

@Test func releaseVelocityComesFromTheLast150ms() {
    var t = SwipeTracker()
    t.push(500, at: 0)
    for i in 1...10 { t.push(10, at: 0.5 + Double(i) * 0.01) }
    #expect(abs(t.velocity - 90 / 0.09) < 1e-6)
    #expect(abs(t.projectedEnd - t.position - t.velocity * 0.33283) < 0.5)
}

@Test func draggingAtAnEdgeScrollsNoFurtherThanTheStripsEnds() {
    var (w, c) = strip(3)
    w.edgeScroll(monitor: 0, by: -500, config: c)
    #expect(w.layout(config: c)[1]?.frame.minX == 10)
    w.edgeScroll(monitor: 0, by: 5000, config: c)
    #expect(w.layout(config: c)[3]?.frame.maxX == 990)
    #expect(w.focusedWindow == 1)
}

@Test func aStripThatFitsDoesNotScrollAtTheEdge() {
    var (w, c) = strip(1)
    let before = w.layout(config: c)[1]?.frame
    w.edgeScroll(monitor: 0, by: 300, config: c)
    #expect(w.layout(config: c)[1]?.frame == before)
}

@Test func releaseSpeedDoesNotIncludeTravelBeforeTheFirstSample() {
    var tracker = SwipeTracker()
    tracker.push(100, at: 1)
    tracker.push(10, at: 1.01)
    #expect(abs(tracker.velocity - 1000) < 1e-6)
    tracker.push(0, at: 1.3)
    #expect(tracker.velocity == 0)
}
