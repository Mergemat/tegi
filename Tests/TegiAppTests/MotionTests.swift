import CoreGraphics
import Testing
import TegiCore
@testable import tegi

private let springs = Motion.Springs(position: .view, size: .view, slowdown: 1)

@Test func releasingASwipeDuringAMoveDoesNotJumpBackToTheOldSpringOrigin() {
    let motion = Motion()
    let from = CGRect(x: 0, y: 0, width: 100, height: 100)
    let to = from.offsetBy(dx: 500, dy: 0)
    _ = motion.move(1, from: from, to: to, monitor: 0, at: 0, springs: springs)
    let before = motion.current(1, at: 0.03)!.frame
    _ = motion.move(1, from: before, to: to, monitor: 0, at: 0.03, velocity: 1000, springs: springs)
    #expect(abs(motion.current(1, at: 0.03)!.frame.minX - before.minX) < 0.001)
}
