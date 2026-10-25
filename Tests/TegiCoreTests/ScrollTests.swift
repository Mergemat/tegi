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

@Test func aFlickCoastsToTheNextColumnAndFocusesIt() {
    var (w, c) = strip(4)
    let start = w.viewPosition(monitor: 0, config: c)
    w.scrollView(monitor: 0, by: 200, config: c)
    var t = SwipeTracker()
    for i in 0..<10 { t.push(20, at: Double(i) * 0.01) }
    w.endSwipe(monitor: 0, coastingTo: start + 200 + t.projectedEnd - t.position, config: c)
    #expect(w.layout(config: c)[w.focusedWindow!]?.visible == true)
    #expect(w.focusedWindow! > 2)
    let snapped = w.viewPosition(monitor: 0, config: c)
    let leftEdges = w.layout(config: c).values.filter(\.visible).map(\.frame.minX)
    #expect(leftEdges.contains(10) || leftEdges.contains { $0 + 485 == 990 })
    #expect(snapped > start)
}

@Test func aGentleDragSnapsBackAndFocusesTheFurthestVisibleColumnThatWay() {
    var (w, c) = strip(3)
    let start = w.viewPosition(monitor: 0, config: c)
    w.scrollView(monitor: 0, by: 60, config: c)
    w.endSwipe(monitor: 0, coastingTo: start + 60, config: c)
    #expect(w.viewPosition(monitor: 0, config: c) == start)
    #expect(w.focusedWindow == 2)
}

@Test func aSwipeNeverSnapsPastTheEnds() {
    var (w, c) = strip(3)
    w.scrollView(monitor: 0, by: -900, config: c)
    w.endSwipe(monitor: 0, coastingTo: -5000, config: c)
    #expect(w.layout(config: c)[1]?.frame.minX == 10)
    w.endSwipe(monitor: 0, coastingTo: 50_000, config: c)
    #expect(w.layout(config: c)[3]?.frame.maxX == 990)
    #expect(w.focusedWindow == 3)
}

@Test func releaseVelocityComesFromTheLast150ms() {
    var t = SwipeTracker()
    t.push(500, at: 0)
    for i in 1...10 { t.push(10, at: 0.5 + Double(i) * 0.01) }
    #expect(abs(t.velocity - 100 / 0.09) < 1e-6)
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
