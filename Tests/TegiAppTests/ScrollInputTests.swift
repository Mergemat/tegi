import CoreGraphics
import Testing
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
    _ = input.handle(scroll(phase: 2, dx: -30), held: false, claim: (3, 3), send: receive)
    _ = input.handle(scroll(phase: 4), held: false, claim: (3, 0), send: receive)
    _ = input.handle(scroll(momentum: 1, dx: -12), held: false, claim: (3, 0), send: receive)
    _ = input.handle(scroll(momentum: 2, dx: -2), held: false, claim: (0, 0), send: receive)
    _ = input.handle(scroll(momentum: 3), held: false, claim: (0, 0), send: receive)
    #expect(coast == [-12, -2])
    #expect(ended)
}

@Test func aNewUnmodifiedScrollEndsTheOldCoastAndGoesToTheApp() {
    var input = ScrollInput()
    var ended = false
    func receive(_ event: InputTap.Event) {
        if case .momentumEnded = event { ended = true }
    }
    _ = input.handle(scroll(phase: 1), held: true, claim: (0, 0), send: receive)
    _ = input.handle(scroll(phase: 4), held: false, claim: (0, 0), send: receive)
    let passed = input.handle(scroll(phase: 1), held: false, claim: (0, 0), send: receive)
    #expect(passed != nil)
    #expect(ended)
}

@Test func fourFingerMomentumNeverScrollsTheStripOrTheApp() {
    var input = ScrollInput()
    var sent = 0
    for event in [scroll(phase: 1), scroll(phase: 2, dx: -40), scroll(phase: 4),
                  scroll(momentum: 1, dx: -10), scroll(momentum: 3)] {
        let passed = input.handle(event, held: false, claim: (4, 4)) { _ in sent += 1 }
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
    _ = input.handle(scroll(phase: 1), held: true, claim: (0, 0), send: receive)
    _ = input.handle(scroll(phase: 2, dx: -20), held: false, claim: (0, 0), send: receive)
    _ = input.handle(scroll(phase: 4), held: false, claim: (0, 0), send: receive)
    let passed = input.handle(scroll(momentum: 1, dx: -10), held: false, claim: (0, 0), send: receive)
    #expect(passed == nil)
    #expect(moved == -30)
}
