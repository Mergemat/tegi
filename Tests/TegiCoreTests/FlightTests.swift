import CoreGraphics
import Testing
@testable import TegiCore

private func flight(delay: Double) -> Flight {
    Flight(from: CGRect(x: 0, y: 0, width: 800, height: 600), to: CGRect(x: 1000, y: 0, width: 800, height: 600),
           monitor: 0, velocity: nil, at: 0, delay: delay, position: .view, size: .view, slowdown: 1)
}

@Test func aHeldBackWindowWaitsThenSetsOff() {
    let f = flight(delay: 0.05)
    #expect(f.frame(at: 0.04).minX == 0)
    #expect(f.frame(at: 0.1).minX == flight(delay: 0).frame(at: 0.05).minX)
}

@Test func aHeldBackWindowKeepsGoingWhenItsTargetChanges() {
    // Keys held down retarget every few frames; a held-back window must neither jump nor stall at each one.
    var f = flight(delay: 0.05)
    let frame = 1.0 / 60
    var last = f.frame(at: 0.2).minX
    f.retarget(to: CGRect(x: 2000, y: 0, width: 800, height: 600), at: 0.2)
    #expect(abs(f.frame(at: 0.2).minX - last) < 1e-6)
    for i in 1...6 {
        let x = f.frame(at: 0.2 + Double(i) * frame).minX
        #expect(x > last + 1)
        last = x
    }
}
