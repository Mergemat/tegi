import Testing
import AppKit
import TegiCore
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

@MainActor @Test func cancellingAnOverviewSwipeRestoresItsStartingState() {
    _ = NSApplication.shared
    var config = Config.builtIn
    config.animations.on = false
    config.animations.windowServer = false
    let manager = WindowManager(config: config)
    manager.touch(.began(fingers: 4))
    manager.touch(.changed(dx: 0, dy: -0.2, time: 1))
    #expect(manager.overview)
    manager.touch(.cancelled)
    #expect(!manager.overview)
    #expect(manager.overviewSwipe == nil)
    manager.setOverview(true)
    manager.touch(.began(fingers: 4))
    manager.touch(.changed(dx: 0, dy: 0.2, time: 2))
    manager.touch(.cancelled)
    #expect(manager.overview)
    #expect(manager.overviewSwipe == nil)
    manager.setOverview(false)
}
