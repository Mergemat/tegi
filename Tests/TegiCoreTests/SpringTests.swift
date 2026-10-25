import Testing
@testable import TegiCore

@Test func springSettlesOnTargetInAThirdOfASecond() {
    let s = Spring(from: 0, to: 500, start: 10)
    #expect(abs(Spring.duration - 0.3257) < 0.001)
    #expect(s.value(at: 10) == 0)
    #expect(s.value(at: 10 + Spring.duration) == 500)
    #expect(s.value(at: 10.15) > 450)
}

@Test func fromRestItNeverOvershoots() {
    let s = Spring(from: 0, to: 500, start: 0)
    var last = 0.0
    for i in 0...400 {
        let v = s.value(at: Double(i) / 1000)
        #expect(v <= 500 && v >= last)
        last = v
    }
}

@Test func retargetingMidMotionIsContinuous() {
    let s = Spring(from: 0, to: 500, start: 0)
    let t = 0.08
    let r = s.retargeted(to: -300, at: t)
    #expect(abs(r.value(at: t) - s.value(at: t)) < 1e-9)
    #expect(abs(r.velocity(at: t) - s.velocity(at: t)) < 1e-6)
    #expect(r.value(at: t + Spring.duration) == -300)
}

@Test func workspaceSpringIsStifferAndShorter() {
    let s = Spring(from: 0, to: 1, start: 0, params: .workspace)
    #expect(abs(s.duration - 0.2913) < 0.001)
    #expect(s.value(at: 0.2913) == 1)
}

@Test func rubberBandResistsAndNeverPassesItsLimit() {
    let band = RubberBand.workspaces
    #expect(band.clamp(1.5, 0, 2) == 1.5)
    let past = band.clamp(2.5, 0, 2)
    #expect(past > 2 && past < 2.05)
    #expect(band.clamp(100, 0, 2) < 2.05)
    #expect(band.clampDerivative(2.5, 0, 2) < 1)
}

@Test func aBouncySpringOvershootsThenSettles() {
    let s = Spring(from: 0, to: 100, start: 0, params: SpringParams(dampingRatio: 0.6, stiffness: 1000, epsilon: 0.001))
    let peak = stride(from: 0.0, to: s.duration, by: 0.001).map { s.value(at: $0) }.max()!
    #expect(peak > 100)
    #expect(s.value(at: s.duration) == 100)
}

@Test func slowdownStretchesTimeAndNothingElse() {
    let normal = Spring(from: 0, to: 100, start: 0)
    let slow = Spring(from: 0, to: 100, start: 0, slowdown: 3)
    #expect(abs(slow.duration - normal.duration * 3) < 1e-9)
    #expect(abs(slow.value(at: 0.09) - normal.value(at: 0.03)) < 1e-9)
}

@Test func velocityIsExactForBouncySpringsToo() {
    let s = Spring(from: 0, to: 100, velocity: 50, start: 0, params: SpringParams(dampingRatio: 0.5, stiffness: 600), slowdown: 1.5)
    for t in [0.0, 0.05, 0.2] {
        let h = 1e-6
        let numeric = (s.value(at: t + h) - s.value(at: t)) / h
        #expect(abs(numeric - s.velocity(at: t)) < 0.05)
    }
}
