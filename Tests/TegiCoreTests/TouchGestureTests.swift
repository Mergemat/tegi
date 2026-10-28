import Testing
@testable import TegiCore

private struct Trackpad {
    var gestures = TouchGestures()
    var number: Int32 = 0
    var scrollRouting: TouchGestures.ScrollRouting { gestures.scrollRouting }
    mutating func frame(_ touches: [TouchGestures.Touch]) -> [TouchGestures.Event] {
        number += 1
        return gestures.frame(.init(time: Double(number) / 120, number: number, touches: touches))
    }
}

/// Fingers down at once, by id, each at x, y in trackpad widths.
private func fingers(_ points: [(Int32, Double, Double)]) -> [TouchGestures.Touch] {
    points.map { TouchGestures.Touch(id: $0.0, x: $0.1, y: $0.2) }
}

private func hand(_ count: Int, dx: Double = 0, dy: Double = 0) -> [TouchGestures.Touch] {
    fingers((0..<count).map { (Int32($0), 0.3 + 0.1 * Double($0) + dx, 0.5 + dy) })
}

@Test func fourFingersLandingOneByOneMakeOneFourFingerGestureAndNeverAThreeFingerOne() {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    // Each contact lands on a successive frame, drifting a little as it does.
    for n in 1...4 { events += g.frame(hand(n, dy: 0.002 * Double(n))) }
    for step in 1...10 { events += g.frame(hand(4, dy: 0.008 + 0.02 * Double(step))) }
    for n in (0...3).reversed() { events += g.frame(hand(n, dy: 0.2)) }
    #expect(events.first == .began(fingers: 4))
    #expect(events.last == .ended)
    let rise = events.reduce(0.0) { if case .changed(_, let dy) = $1 { $0 + dy } else { $0 } }
    #expect(events.filter { if case .began = $0 { true } else { false } }.count == 1)
    #expect(events.filter { $0 == .ended }.count == 1)
    // Following the fingers from where the gesture was decided.
    #expect(rise > 0 && rise <= 0.2)
    #expect(events.allSatisfy { if case .changed(_, let dy) = $0 { abs(dy - 0.02) < 1e-9 } else { true } })
}

@Test func threeFingersMoveTheStripByHowFarTheyMoveAndAFingerLandingMovesNothing() {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for n in 1...3 { events += g.frame(hand(n)) }
    for step in 1...6 { events += g.frame(hand(3, dx: 0.01 * Double(step))) }
    #expect(events.first == .began(fingers: 3))
    let moves = events.dropFirst().compactMap { if case .changed(let dx, let dy) = $0 { (dx, dy) } else { nil } }
    #expect(moves.count == events.count - 1 && !moves.isEmpty)
    #expect(moves.allSatisfy { abs($0.0 - 0.01) < 1e-9 && abs($0.1) < 1e-9 })
    // A fourth contact contributes no movement to the selected fingers.
    let landed = g.frame(hand(3, dx: 0.06) + fingers([(9, 0.9, 0.1)]))
    #expect(landed == [.changed(dx: 0, dy: 0)])
    #expect(g.frame([]) == [.ended])
}

@Test func aTremorBelowTheTravelThresholdStartsNothing() {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for n in 1...3 { events += g.frame(hand(n)) }
    for step in 1...4 { events += g.frame(hand(3, dx: 0.005 * Double(step))) }
    events += g.frame([])
    #expect(events.isEmpty)
}

@Test func twoFingersAreTheSystemsScrollNotAGesture() {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for step in 0...10 { events += g.frame(hand(2, dx: 0.02 * Double(step))) }
    // Even when a third finger joins mid-scroll.
    for step in 11...20 { events += g.frame(hand(3, dx: 0.02 * Double(step))) }
    #expect(events.isEmpty)
}

@Test func scrollRoutingFollowsMovingFingersUntilTheyLift() {
    var g = Trackpad()
    _ = g.frame(hand(3))
    #expect(g.scrollRouting == .pending)
    _ = g.frame(hand(3, dx: 0.01))
    #expect(g.scrollRouting == .pending)
    for step in 2...6 { _ = g.frame(hand(3, dx: Double(step) * 0.01)) }
    #expect(g.scrollRouting == .strip)
    _ = g.frame(hand(1, dx: 0.04))
    #expect(g.scrollRouting == .suppress)
    _ = g.frame([])
    #expect(g.scrollRouting == .system)
    // A two-finger scroll stays the system's when a third finger joins it.
    for step in 0...5 { _ = g.frame(hand(2, dx: 0.02 * Double(step))) }
    _ = g.frame(hand(3, dx: 0.12))
    #expect(g.scrollRouting == .system)
}

@Test(arguments: [2, 3, 4]) func aRestingPalmDoesNotCountAsASwipingFinger(count: Int) {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for step in 0...8 {
        events += g.frame(hand(count, dx: Double(step) * 0.01) + fingers([(9, 0.9, 0.05)]))
        if count == 2 { #expect(g.scrollRouting == .system || g.scrollRouting == .pending) }
    }
    let beginnings = events.filter { if case .began = $0 { true } else { false } }
    #expect(beginnings == (count == 2 ? [] : [.began(fingers: count)]))
}

@Test func brushingTheTrackpadDoesNotInterruptAnActiveSwipe() {
    var g = Trackpad()
    for step in 0...6 { _ = g.frame(hand(3, dx: Double(step) * 0.01)) }
    let moved = g.frame(hand(3, dx: 0.08) + fingers([(9, 0.9, 0.05)]))
    #expect(moved.count == 1)
    if case .changed(let dx, let dy) = moved.first {
        #expect(abs(dx - 0.02) < 1e-9 && dy == 0)
    } else {
        Issue.record("A stray contact interrupted the swipe")
    }
    #expect(g.frame(hand(3, dx: 0.09)).allSatisfy { if case .changed = $0 { true } else { false } })
}

@Test func replacingASwipingFingerEndsTheGestureEvenWhenTheCountStaysTheSame() {
    var g = Trackpad()
    for step in 0...6 { _ = g.frame(hand(3, dx: Double(step) * 0.01)) }
    #expect(g.frame(hand(2, dx: 0.07) + fingers([(9, 0.9, 0.05)])) == [.ended])
}

@Test(arguments: [2, 3, 4]) func aMovingPalmIsRejectedEvenWhenItMovesWithTheFingers(count: Int) {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for step in 0...8 {
        let dx = Double(step) * 0.01
        let fingers = hand(count, dx: dx).map { TouchGestures.Touch(id: $0.id, x: $0.x, y: $0.y, area: 80) }
        // Once recognized as a palm, rolling onto a smaller part of it must not make it a finger.
        let palm = TouchGestures.Touch(id: 9, x: 0.9 + dx, y: 0.05, area: step < 2 ? 300 : 90)
        events += g.frame(fingers + [palm])
        if count == 2 { #expect(g.scrollRouting == .system || g.scrollRouting == .pending) }
    }
    let beginnings = events.filter { if case .began = $0 { true } else { false } }
    #expect(beginnings == (count == 2 ? [] : [.began(fingers: count)]))
}

@Test(arguments: [3, 4]) func unevenFingerMovementStillMakesOneSwipe(count: Int) {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    let speeds = [0.8, 1.0, 1.2, 0.65]
    for step in 0...10 {
        events += g.frame(hand(count).enumerated().map { index, touch in
            .init(id: touch.id, x: touch.x + Double(step) * 0.01 * speeds[index],
                  y: touch.y + Double(step) * 0.002 * speeds[index])
        })
    }
    #expect(events.filter { if case .began = $0 { true } else { false } } == [.began(fingers: count)])
}

@Test func aPalmMovingAcrossATwoFingerScrollDoesNotBecomeAThirdFinger() {
    var g = Trackpad()
    var events: [TouchGestures.Event] = []
    for step in 0...8 {
        let travel = Double(step) * 0.01
        events += g.frame(hand(2, dx: travel) + fingers([(9, 0.9, 0.05 + travel)]))
        #expect(g.scrollRouting == .system || g.scrollRouting == .pending)
    }
    #expect(g.scrollRouting == .system)
    #expect(events.isEmpty)
}

@Test(arguments: [2, 3, 4]) func liftingOnlyTheFingersAllowsAnotherGestureWhileThePalmRests(count: Int) {
    var g = Trackpad()
    let palm = fingers([(9, 0.9, 0.05)])
    for step in 0...8 { _ = g.frame(hand(count, dx: Double(step) * 0.01) + palm) }
    _ = g.frame(palm)
    var events: [TouchGestures.Event] = []
    for step in 0...8 { events += g.frame(hand(3, dx: Double(step) * 0.01) + palm) }
    #expect(events.filter { if case .began = $0 { true } else { false } } == [.began(fingers: 3)])
}

@Test func anInvalidFrameDoesNotReleaseTheFingersOrInventMotionAcrossTheGap() {
    var gestures = TouchGestures()
    _ = gestures.frame(.init(time: 1, number: 1, touches: hand(4)))
    #expect(gestures.frame(.init(time: 2, number: 2, touches: hand(4, dy: 0.04))) == [.began(fingers: 4)])
    #expect(gestures.frame(.init(time: 3, number: 3, touches: [], valid: false)).isEmpty)
    #expect(gestures.frame(.init(time: 4, number: 4, touches: hand(4, dy: 0.1))).isEmpty)
    let events = gestures.frame(.init(time: 5, number: 5, touches: hand(4, dy: 0.12)))
    guard case .changed(_, let dy) = events.first else { Issue.record("Gesture did not resume"); return }
    #expect(abs(dy - 0.02) < 1e-9)
    #expect(gestures.frame(.init(time: 6, number: 6, touches: [])) == [.ended])
}

@Test func staleFramesCannotMoveOrEndANewerGesture() {
    var gestures = TouchGestures()
    _ = gestures.frame(.init(time: 1, number: 1, touches: hand(3)))
    _ = gestures.frame(.init(time: 2, number: 2, touches: hand(3, dx: 0.04)))
    #expect(gestures.frame(.init(time: 1.5, number: 3, touches: [])).isEmpty)
    #expect(gestures.scrollRouting == .strip)
    let events = gestures.frame(.init(time: 3, number: 4, touches: hand(3, dx: 0.06)))
    guard case .changed(let dx, _) = events.first else { Issue.record("Gesture ended on a stale frame"); return }
    #expect(abs(dx - 0.02) < 1e-9)
}

@Test func contactMakeAndBreakStatesHaveExplicitLifetimes() {
    var gestures = TouchGestures()
    func contacts(_ dy: Double, state: Int32) -> [TouchGestures.Touch] {
        hand(4, dy: dy).map { .init(id: $0.id, x: $0.x, y: $0.y, state: state) }
    }
    _ = gestures.frame(.init(time: 1, number: 1, touches: contacts(0, state: 3)))
    #expect(gestures.frame(.init(time: 2, number: 2, touches: contacts(0.04, state: 4))) == [.began(fingers: 4)])
    #expect(gestures.frame(.init(time: 3, number: 3, touches: contacts(0.04, state: 5))) == [.ended])
    #expect(gestures.frame(.init(time: 4, number: 4, touches: contacts(0.04, state: 6))).isEmpty)
}

@Test func cancellingAnActiveGestureIsDistinctFromReleasingItAndAllowsAFreshGesture() {
    var gestures = TouchGestures()
    _ = gestures.frame(.init(time: 1, number: 1, touches: hand(4)))
    _ = gestures.frame(.init(time: 2, number: 2, touches: hand(4, dy: 0.04)))
    #expect(gestures.cancel() == [.cancelled])
    #expect(gestures.cancel().isEmpty)
    #expect(gestures.scrollRouting == .system)
    _ = gestures.frame(.init(time: 3, number: 3, touches: hand(3)))
    #expect(gestures.frame(.init(time: 4, number: 4, touches: hand(3, dx: 0.04))) == [.began(fingers: 3)])
}

@Test func aReleaseDoesNotNeedAUsableContactPosition() {
    var gestures = TouchGestures()
    _ = gestures.frame(.init(time: 1, number: 1, touches: hand(4)))
    _ = gestures.frame(.init(time: 2, number: 2, touches: hand(4, dy: 0.04)))
    let released = hand(4).map { TouchGestures.Touch(id: $0.id, x: .nan, y: .nan, state: 5) }
    #expect(gestures.frame(.init(time: 3, number: 3, touches: released)) == [.ended])
}

@Test func nativeScrollReservationEndsWithEachContactsLifetimeIncludingARestingPalm() {
    var gestures = TouchGestures()
    let palm = fingers([(9, 0.9, 0.05)])
    _ = gestures.frame(.init(time: 1, number: 1, touches: hand(2) + palm))
    #expect(gestures.reserveForNativeScroll().isEmpty)
    #expect(gestures.frame(.init(time: 2, number: 2, touches: hand(2, dx: 0.08) + palm)).isEmpty)
    _ = gestures.frame(.init(time: 3, number: 3, touches: palm))
    _ = gestures.frame(.init(time: 4, number: 4, touches: hand(3) + palm))
    #expect(gestures.frame(.init(time: 5, number: 5, touches: hand(3, dx: 0.04) + palm)) == [.began(fingers: 3)])
}

@Test func aFourthFingerGetsTheSameMotionBaselineAsTheFirstThree() {
    var gestures = TouchGestures()
    func frame(_ time: Double, _ touches: [TouchGestures.Touch]) -> [TouchGestures.Event] {
        gestures.frame(.init(time: time, number: Int32(time * 120), touches: touches))
    }
    var events = frame(1, hand(3))
    events += frame(1.016, hand(3, dy: 0.04))
    events += frame(1.024, hand(3, dy: 0.05) + [hand(4)[3]])
    for step in 1...10 {
        events += frame(1.024 + Double(step) / 120,
                        hand(3, dy: 0.05 + Double(step) * 0.01) + [hand(4, dy: Double(step) * 0.01)[3]])
    }
    #expect(events.filter { if case .began = $0 { true } else { false } } == [.began(fingers: 4)])
}
