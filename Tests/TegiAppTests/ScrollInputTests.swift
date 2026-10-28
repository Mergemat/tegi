import CoreGraphics
import Testing
import TegiCore
@testable import tegi

private func scroll(phase: Int64 = 0, momentum: Int64 = 0, dx: Double = 0) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    return event
}

@Test func liftingFingersDoesNotSwallowTheNativeCoast() {
    var input = ScrollInput()
    var coast: [Double] = []
    var ended = false
    func receive(_ event: InputTap.Event) {
        if case .momentum(let dx, _, _) = event { coast.append(dx) }
        if case .momentumEnded = event { ended = true }
    }
    _ = input.handle(scroll(phase: 2, dx: -30), held: false, routing: .strip, send: receive)
    _ = input.handle(scroll(phase: 4), held: false, routing: .suppress, send: receive)
    _ = input.handle(scroll(momentum: 1, dx: -12), held: false, routing: .suppress, send: receive)
    _ = input.handle(scroll(momentum: 2, dx: -2), held: false, routing: .system, send: receive)
    _ = input.handle(scroll(momentum: 3), held: false, routing: .system, send: receive)
    #expect(coast == [-12, -2])
    #expect(ended)
}

@Test func aNewUnmodifiedScrollEndsTheOldCoastAndGoesToTheApp() {
    var input = ScrollInput()
    var ended = false
    func receive(_ event: InputTap.Event) {
        if case .momentumEnded = event { ended = true }
    }
    _ = input.handle(scroll(phase: 1), held: true, routing: .system, send: receive)
    _ = input.handle(scroll(phase: 4), held: false, routing: .system, send: receive)
    let passed = input.handle(scroll(phase: 1), held: false, routing: .system, send: receive)
    #expect(passed != nil)
    #expect(ended)
}

@Test func fourFingerMomentumNeverScrollsTheStripOrTheApp() {
    var input = ScrollInput()
    var sent = 0
    for event in [scroll(phase: 1), scroll(phase: 2, dx: -40), scroll(phase: 4),
                  scroll(momentum: 1, dx: -10), scroll(momentum: 3)] {
        let passed = input.handle(event, held: false, routing: .suppress) { _ in sent += 1 }
        #expect(passed == nil)
    }
    #expect(sent == 0)
}

@Test func modifierScrollKeepsItsMomentumAfterTheModifierIsReleased() {
    var input = ScrollInput()
    var moved = 0.0
    func receive(_ event: InputTap.Event) {
        switch event {
        case .changed(let dx, _, _), .momentum(let dx, _, _): moved += dx
        default: break
        }
    }
    _ = input.handle(scroll(phase: 1), held: true, routing: .system, send: receive)
    _ = input.handle(scroll(phase: 2, dx: -20), held: false, routing: .system, send: receive)
    _ = input.handle(scroll(phase: 4), held: false, routing: .system, send: receive)
    let passed = input.handle(scroll(momentum: 1, dx: -10), held: false, routing: .system, send: receive)
    #expect(passed == nil)
    #expect(moved == -30)
}

@Test func twoFingerScrollingWithARestingPalmGoesToTheApp() {
    var gestures = TouchGestures(), input = ScrollInput()
    var sent = 0
    var delivered: [Double] = []
    for step in 0...8 {
        let dx = Double(step) * 0.01
        _ = gestures.frame(.init(time: Double(step), number: Int32(step), touches: [.init(id: 1, x: 0.3 + dx, y: 0.5), .init(id: 2, x: 0.4 + dx, y: 0.5),
                            .init(id: 9, x: 0.9, y: 0.05)]))
        let event = scroll(phase: step == 0 ? 1 : 2, dx: 10)
        let passed = input.handle(event, held: false, routing: gestures.scrollRouting,
                                  replay: { delivered.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) }) { _ in sent += 1 }
        if passed != nil { delivered.append(10) }
    }
    #expect(delivered == Array(repeating: 10, count: 9))
    #expect(sent == 0)
}

@Test func tentativeThirdContactDoesNotSwallowTheRestOfATwoFingerScroll() {
    var gestures = TouchGestures()
    var input = ScrollInput()
    var sent = 0
    for step in 0...8 {
        let dx = Double(step) * 0.01
        _ = gestures.frame(.init(time: Double(step), number: Int32(step), touches: [.init(id: 1, x: 0.3 + dx, y: 0.5), .init(id: 2, x: 0.4 + dx, y: 0.5),
                            .init(id: 9, x: 0.9 + min(dx, 0.01), y: 0.05)]))
        let passed = input.handle(scroll(phase: step == 0 ? 1 : 2, dx: 10), held: false,
                                  routing: gestures.scrollRouting) { _ in sent += 1 }
        if step >= 4 { #expect(passed != nil) }
    }
    #expect(sent == 0)
}

@Test func confirmedOverviewSuppressionOutlastsFingerReleaseButEndsOnANewSystemScroll() {
    var input = ScrollInput()
    var sent = 0
    _ = input.handle(scroll(phase: 1), held: false, routing: .suppress) { _ in sent += 1 }
    _ = input.handle(scroll(phase: 2, dx: 40), held: false, routing: .suppress) { _ in sent += 1 }
    for event in [scroll(phase: 4), scroll(momentum: 1, dx: 10), scroll(momentum: 3)] {
        #expect(input.handle(event, held: false, routing: .system) { _ in sent += 1 } == nil)
    }
    #expect(input.handle(scroll(phase: 1), held: false, routing: .system) { _ in sent += 1 } != nil)
    #expect(sent == 0)
}

@Test func undecidedContactsPreserveTheEntireSystemScrollSequence() {
    var input = ScrollInput()
    var sent = 0
    var delivered: [Double] = []
    for event in [scroll(phase: 1, dx: 2), scroll(phase: 2, dx: 8), scroll(phase: 4),
                  scroll(momentum: 1, dx: 4), scroll(momentum: 3)] {
        if input.handle(event, held: false, routing: .pending,
                        replay: { delivered.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) },
                        send: { _ in sent += 1 }) != nil {
            delivered.append(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        }
    }
    #expect(delivered == [2, 8, 0, 4, 0])
    #expect(sent == 0)
}

@Test func anAppOwnedScrollCannotBeTakenOverByLateContactsOrAModifier() {
    var input = ScrollInput()
    var sent = 0
    #expect(input.handle(scroll(phase: 1), held: false, routing: .system) { _ in sent += 1 } != nil)
    for event in [scroll(phase: 2, dx: 20), scroll(phase: 4), scroll(momentum: 1, dx: 10), scroll(momentum: 3)] {
        #expect(input.handle(event, held: true, routing: .strip) { _ in sent += 1 } != nil)
    }
    #expect(sent == 0)
}

@Test func aTerminalEventCannotStartAStripGesture() {
    var input = ScrollInput()
    var sent = 0
    #expect(input.handle(scroll(phase: 4), held: false, routing: .strip) { _ in sent += 1 } != nil)
    #expect(sent == 0)
}

@Test func combinedScrollPhasesPreserveTheirMovement() {
    var input = ScrollInput()
    var moved = 0.0
    _ = input.handle(scroll(phase: 1 | 2, dx: 12), held: false, routing: .strip) {
        if case .changed(let dx, _, _) = $0 { moved += dx }
    }
    #expect(moved == 12)
}

@Test func anInputRestartDrainsTegiScrollsAndPreservesAppScrolls() {
    for routing: TouchGestures.ScrollRouting in [.system, .strip, .suppress] {
        var input = ScrollInput()
        _ = input.handle(scroll(phase: 1), held: false, routing: routing) { _ in }
        input = input.forRestart(replay: { _ in })
        var sent = 0
        for event in [scroll(phase: 2, dx: 10), scroll(phase: 4), scroll(momentum: 1, dx: 3), scroll(momentum: 3)] {
            let result = input.handle(event, held: false, routing: .system) { _ in sent += 1 }
            #expect((result != nil) == (routing == .system))
        }
        #expect(sent == 0)
        #expect(input.handle(scroll(phase: 1), held: false, routing: .system) { _ in sent += 1 } != nil)
    }
}

@Test func recognizingThreeFingersDeliversTheBufferedMotionToTheStrip() {
    var input = ScrollInput()
    var moved = 0.0, began = 0, replayed = 0
    func receive(_ event: InputTap.Event) {
        if case .began = event { began += 1 }
        if case .changed(let dx, _, _) = event { moved += dx }
    }
    #expect(input.handle(scroll(phase: 1, dx: 2), held: false, routing: .pending, send: receive) == nil)
    #expect(input.handle(scroll(phase: 2, dx: 5), held: false, routing: .pending, send: receive) == nil)
    #expect(!input.blocksTouches)
    #expect(input.handle(scroll(phase: 2, dx: 8), held: false, routing: .strip,
                         replay: { _ in replayed += 1 }, send: receive) == nil)
    #expect(began == 1)
    #expect(moved == 15)
    #expect(replayed == 0)
}

@Test func recognizingFourFingersSuppressesTheEntireBufferedSequence() {
    var input = ScrollInput()
    var sent = 0, replayed = 0
    for (event, routing): (CGEvent, TouchGestures.ScrollRouting) in [
        (scroll(phase: 1, dx: 2), .pending), (scroll(phase: 2, dx: 5), .pending),
        (scroll(phase: 2, dx: 8), .suppress), (scroll(phase: 4), .system),
        (scroll(momentum: 1, dx: 4), .system), (scroll(momentum: 3), .system)
    ] {
        #expect(input.handle(event, held: false, routing: routing,
                             replay: { _ in replayed += 1 }, send: { _ in sent += 1 }) == nil)
    }
    #expect(sent == 0)
    #expect(replayed == 0)
}

@Test func restartingAnUndecidedScrollReturnsItsPrefixToTheApp() {
    var input = ScrollInput()
    _ = input.handle(scroll(phase: 1, dx: 2), held: false, routing: .pending) { _ in }
    _ = input.handle(scroll(phase: 2, dx: 8), held: false, routing: .pending) { _ in }
    var delivered: [Double] = []
    input = input.forRestart(replay: { delivered.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) })
    #expect(delivered == [2, 8])
    #expect(input.owner == .system)
    #expect(input.handle(scroll(phase: 4), held: false, routing: .system) { _ in } != nil)
}

@Test func undecidedMotionTimesOutToTheAppWithItsPrefixIntact() {
    var input = ScrollInput()
    let began = scroll(phase: 1, dx: 2), changed = scroll(phase: 2, dx: 8)
    began.timestamp = 1_000_000_000
    changed.timestamp = 1_100_000_000
    var delivered: [Double] = []
    #expect(input.handle(began, held: false, routing: .pending) { _ in } == nil)
    #expect(input.handle(changed, held: false, routing: .pending,
                         replay: { delivered.append($0.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) },
                         send: { _ in Issue.record("Ambiguous motion took the strip") }) != nil)
    #expect(delivered == [2])
    #expect(input.owner == .system)
    #expect(input.blocksTouches)
}
