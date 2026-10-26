import CoreGraphics
import Testing
import TegiCore
@testable import tegi

private let springs = Motion.Springs(position: .view, size: .view, slowdown: 1)

@Test func compositorResizesStaySnappedWhenAMovingWindowIsRetargeted() {
    let motion = Motion()
    let from = CGRect(x: 0, y: 0, width: 100, height: 100)
    let first = CGRect(x: 500, y: 0, width: 200, height: 200)
    _ = motion.move(1, from: from, to: first, monitor: 0, at: 0, springs: springs, animateSize: false)
    #expect(motion.current(1, at: 0)?.frame.size == first.size)
    let before = motion.current(1, at: 0.03)!.frame
    let next = CGRect(x: 700, y: 100, width: 300, height: 400)
    _ = motion.move(1, from: before, to: next, monitor: 0, at: 0.03, springs: springs, animateSize: false)
    #expect(motion.current(1, at: 0.03)?.frame.origin == before.origin)
    #expect(motion.current(1, at: 0.03)?.frame.size == next.size)
    #expect(motion.current(1, at: 0.05)?.frame.size == next.size)
}

@Test func releasingASwipeDuringAMoveDoesNotJumpBackToTheOldSpringOrigin() {
    let motion = Motion()
    let from = CGRect(x: 0, y: 0, width: 100, height: 100)
    let to = from.offsetBy(dx: 500, dy: 0)
    _ = motion.move(1, from: from, to: to, monitor: 0, at: 0, springs: springs)
    let before = motion.current(1, at: 0.03)!.frame
    _ = motion.move(1, from: before, to: to, monitor: 0, at: 0.03, velocity: 1000, springs: springs)
    #expect(abs(motion.current(1, at: 0.03)!.frame.minX - before.minX) < 0.001)
}
