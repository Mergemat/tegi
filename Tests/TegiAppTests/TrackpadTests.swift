import Testing
import TegiCore
import CoreGraphics
@testable import tegi

private func contactFrame(_ count: Int, at time: Double, dy: Double = 0) -> TouchGestures.Frame {
    .init(time: time, number: Int32(time * 120), touches: (0..<count).map {
        .init(id: Int32($0), x: 0.3 + Double($0) * 0.1, y: 0.5 + dy)
    })
}

@Test func anIdleSecondDeviceCannotEndTheFirstDevicesGesture() {
    var input = TrackpadGestures()
    _ = input.frame(contactFrame(4, at: 1), device: 10)
    #expect(input.frame(contactFrame(4, at: 2, dy: 0.04), device: 10) == [.began(fingers: 4)])
    #expect(input.frame(contactFrame(0, at: 3), device: 20).isEmpty)
    #expect(input.scrollRouting == .suppress)
    let events = input.frame(contactFrame(4, at: 4, dy: 0.06), device: 10)
    guard case .changed(_, let dy) = events.first else { Issue.record("Other device ended the gesture"); return }
    #expect(abs(dy - 0.02) < 1e-9)
}

@Test func simultaneousDevicesCancelOnceAndCannotAliasTheirFingerIDs() {
    var input = TrackpadGestures()
    _ = input.frame(contactFrame(4, at: 1), device: 10)
    _ = input.frame(contactFrame(4, at: 2, dy: 0.04), device: 10)
    #expect(input.frame(contactFrame(1, at: 3), device: 20) == [.cancelled])
    #expect(input.scrollRouting == .system)
    #expect(input.frame(contactFrame(4, at: 4, dy: 0.08), device: 10).isEmpty)
    _ = input.frame(contactFrame(0, at: 5), device: 10)
    _ = input.frame(contactFrame(0, at: 6), device: 20)
    _ = input.frame(contactFrame(3, at: 7), device: 20)
    #expect(input.frame(contactFrame(3, at: 8, dy: 0.04), device: 20) == [.began(fingers: 3)])
}

@Test func anAppOwnedScrollCannotAlsoOpenTheRawFourFingerOverview() {
    var input = TrackpadGestures()
    _ = input.frame(contactFrame(4, at: 1), device: 10)
    _ = input.blockTouches(true)
    #expect(input.frame(contactFrame(4, at: 2, dy: 0.04), device: 10).isEmpty)
    #expect(input.scrollRouting == .system)
    _ = input.blockTouches(false)
    #expect(input.frame(contactFrame(4, at: 3, dy: 0.08), device: 10).isEmpty)
    _ = input.frame(contactFrame(0, at: 4), device: 10)
    _ = input.frame(contactFrame(4, at: 5), device: 10)
    #expect(input.frame(contactFrame(4, at: 6, dy: 0.04), device: 10) == [.began(fingers: 4)])
}

@Test func malformedNativeFramesAreNotAllFingersUp() {
    for count in [-1, 1, 21] {
        let decoded = Multitouch.decode(nil, count: count, time: 1, number: 1)
        #expect(!decoded.isValid)
    }
    #expect(Multitouch.decode(nil, count: 0, time: 1, number: 1).isValid)
}

@Test func aRestartCannotRecognizeTheSameFingersAgainWhileTheirScrollDrains() {
    var scroll = ScrollInput()
    let began = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
    began.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    began.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
    _ = scroll.handle(began, held: false, routing: .strip) { _ in }
    scroll = scroll.forRestart(replay: { _ in })
    var touches = TrackpadGestures()
    _ = touches.blockTouches(scroll.blocksTouches)
    _ = touches.frame(contactFrame(4, at: 1), device: 10)
    #expect(touches.frame(contactFrame(4, at: 2, dy: 0.01), device: 10).isEmpty)
    let ended = began.copy()!
    ended.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
    _ = scroll.handle(ended, held: false, routing: .system) { _ in }
    _ = touches.blockTouches(scroll.blocksTouches)
    #expect(touches.frame(contactFrame(4, at: 3, dy: 0.08), device: 10).isEmpty)
    _ = touches.frame(contactFrame(0, at: 4), device: 10)
    _ = touches.frame(contactFrame(4, at: 5), device: 10)
    #expect(touches.frame(contactFrame(4, at: 6, dy: 0.04), device: 10) == [.began(fingers: 4)])
}

@Test func aNativeScrollBeginningBeforeTheRecognitionThresholdStillBecomesAThreeFingerSwipe() {
    var touches = TrackpadGestures(), scroll = ScrollInput()
    _ = touches.frame(contactFrame(3, at: 1), device: 10)
    _ = touches.frame(contactFrame(3, at: 1.02, dy: 0.01), device: 10)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 8, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
    _ = scroll.handle(event, held: false, routing: touches.scrollRouting) { _ in }
    _ = touches.blockTouches(scroll.blocksTouches)
    #expect(touches.frame(contactFrame(3, at: 1.06, dy: 0.04), device: 10) == [.began(fingers: 3)])
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
    var began = false
    _ = scroll.handle(event, held: false, routing: touches.scrollRouting) {
        if case .began = $0 { began = true }
    }
    #expect(began)
    #expect(scroll.owner == .strip)
}

@Test(arguments: [3, 4]) func aShortSwipeKeepsItsDecisionUntilTheNativeEndArrives(count: Int) {
    var touches = TrackpadGestures(), scroll = ScrollInput()
    _ = touches.frame(contactFrame(count, at: 1), device: 10)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
    _ = scroll.handle(event, held: false, routing: touches.scrollRouting) { _ in }
    _ = touches.frame(contactFrame(count, at: 1.05, dy: 0.05), device: 10)
    _ = touches.frame(contactFrame(count - 1, at: 1.06, dy: 0.05), device: 10)
    _ = touches.frame(contactFrame(0, at: 1.07), device: 10)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
    var began = false, ended = false, replayed = false
    #expect(scroll.handle(event, held: false, routing: touches.scrollRouting,
                          replay: { _ in replayed = true }) {
        if case .began = $0 { began = true }
        if case .ended = $0 { ended = true }
    } == nil)
    #expect(!replayed)
    #expect(began == (count == 3))
    #expect(ended == (count == 3))
    _ = touches.frame(contactFrame(2, at: 1.1), device: 10)
    _ = touches.frame(contactFrame(2, at: 1.2, dy: 0.05), device: 10)
    #expect(touches.scrollRouting == .system)
}
