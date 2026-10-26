import Testing
@testable import TegiCore

/// Fingers down at once, by id, each at x, y in trackpad widths.
private func fingers(_ points: [(Int32, Double, Double)]) -> [TouchGestures.Touch] {
    points.map { TouchGestures.Touch(id: $0.0, x: $0.1, y: $0.2) }
}

private func hand(_ count: Int, dx: Double = 0, dy: Double = 0) -> [TouchGestures.Touch] {
    fingers((0..<count).map { (Int32($0), 0.3 + 0.1 * Double($0) + dx, 0.5 + dy) })
}

@Test func fourFingersLandingOneByOneMakeOneFourFingerGestureAndNeverAThreeFingerOne() {
    var g = TouchGestures()
    var events: [TouchGestures.Event] = []
    // They land a few milliseconds apart, drifting a little as they do.
    for n in 1...4 { events += g.frame(hand(n, dy: 0.002 * Double(n))) }
    for step in 1...10 { events += g.frame(hand(4, dy: 0.008 + 0.02 * Double(step))) }
    for n in (0...3).reversed() { events += g.frame(hand(n, dy: 0.2)) }
    #expect(events.first == .began(fingers: 4))
    #expect(events.last == .ended)
    let rise = events.reduce(0.0) { if case .changed(_, let dy) = $1 { $0 + dy } else { $0 } }
    #expect(events.filter { if case .began = $0 { true } else { false } }.count == 1)
    #expect(events.filter { $0 == .ended }.count == 1)
    // Following the fingers from where the gesture was decided.
    #expect(abs(rise - 0.16) < 1e-9)
}

@Test func threeFingersMoveTheStripByHowFarTheyMoveAndAFingerLandingMovesNothing() {
    var g = TouchGestures()
    var events: [TouchGestures.Event] = []
    for n in 1...3 { events += g.frame(hand(n)) }
    for step in 1...6 { events += g.frame(hand(3, dx: 0.01 * Double(step))) }
    #expect(events.first == .began(fingers: 3))
    let moves = events.dropFirst().compactMap { if case .changed(let dx, let dy) = $0 { (dx, dy) } else { nil } }
    #expect(moves.count == events.count - 1 && !moves.isEmpty)
    #expect(moves.allSatisfy { abs($0.0 - 0.01) < 1e-9 && abs($0.1) < 1e-9 })
    // A fourth finger brushing the trackpad ends the swipe, without a jump to its position.
    let landed = g.frame(hand(3, dx: 0.06) + fingers([(9, 0.9, 0.1)]))
    #expect(landed == [.ended])
    #expect(g.frame([]) == [])
}

@Test func aTremorBelowAFewMillimetresStartsNothing() {
    var g = TouchGestures()
    var events: [TouchGestures.Event] = []
    for n in 1...3 { events += g.frame(hand(n)) }
    for step in 1...4 { events += g.frame(hand(3, dx: 0.005 * Double(step))) }
    events += g.frame([])
    #expect(events.isEmpty)
}

@Test func twoFingersAreTheSystemsScrollNotAGesture() {
    var g = TouchGestures()
    var events: [TouchGestures.Event] = []
    for step in 0...10 { events += g.frame(hand(2, dx: 0.02 * Double(step))) }
    // Even when a third finger joins mid-scroll.
    for step in 11...20 { events += g.frame(hand(3, dx: 0.02 * Double(step))) }
    #expect(events.isEmpty)
}

@Test func threeOrFourFingersClaimTheTrackpadUntilTheLastOneLifts() {
    var g = TouchGestures()
    _ = g.frame(hand(2))
    #expect(g.claimed == 0)
    _ = g.frame(hand(3))
    #expect(g.claimed == 3)
    _ = g.frame(hand(4, dy: 0.2))
    #expect(g.claimed == 4)
    _ = g.frame(hand(1, dy: 0.2))
    #expect(g.claimed == 4)
    _ = g.frame([])
    #expect(g.claimed == 0)
    // A two-finger scroll stays the system's when a third finger joins it.
    for step in 0...5 { _ = g.frame(hand(2, dx: 0.02 * Double(step))) }
    _ = g.frame(hand(3, dx: 0.12))
    #expect(g.claimed == 0)
}
