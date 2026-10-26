import Testing
@testable import tegi

@Test func aShortFlickOpensTheOverviewAndASlowShortPushLetsItFallShut() {
    var flick = OverviewSwipe(from: 0)
    for i in 1...5 { flick.tracker.push(12, at: Double(i) * 0.008) }
    #expect(flick.openness < 0.5)
    #expect(flick.release.open && flick.release.rate > 0)

    var push = OverviewSwipe(from: 0)
    for i in 1...20 { push.tracker.push(3, at: Double(i) * 0.05) }
    #expect(!push.release.open)
    // Pulled down from open, past halfway, it closes.
    var pull = OverviewSwipe(from: 1)
    for i in 1...40 { pull.tracker.push(-3, at: Double(i) * 0.05) }
    #expect(!pull.release.open)
}
