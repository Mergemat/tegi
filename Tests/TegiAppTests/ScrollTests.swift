import CoreGraphics
import QuartzCore
import Testing
import TegiCore
@testable import tegi

@MainActor private func scrollingManager() -> WindowManager {
    var config = Config()
    config.animations.on = false
    config.animations.windowServer = false
    let manager = WindowManager(config: config)
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...4 { manager.world.insert(id, config: config) }
    manager.world.perform(.focusColumnFirst, config: config)
    return manager
}

@MainActor @Test func aSmallScrollStartsWithoutASecondDeadZone() {
    let manager = scrollingManager()
    let config = manager.config
    let start = manager.world.viewPosition(monitor: 0, config: config)
    manager.scrolled(.began)
    manager.scrolled(.changed(dx: -4, dy: 0, time: 1))
    #expect(manager.world.viewPosition(monitor: 0, config: config) == start + 4)
}

@MainActor @Test func aFlickChoosesItsColumnOnReleaseAndIgnoresTheNativeTail() {
    let manager = scrollingManager()
    let config = manager.config
    manager.scrolled(.began)
    manager.scrolled(.changed(dx: -60, dy: 0, time: 1))
    manager.scrolled(.changed(dx: -60, dy: 0, time: 1.02))
    manager.scrolled(.ended(time: 1.03))
    let landing = manager.world.viewPosition(monitor: 0, config: config)
    #expect(manager.swipe == nil)
    #expect(landing > 500)
    #expect(abs(manager.world.layout(config: config)[4]!.frame.maxX - CGFloat(1000 - config.gap)) < 0.001)
    manager.scrolled(.momentum(dx: -150, time: 1.04))
    manager.scrolled(.momentumEnded)
    #expect(manager.world.viewPosition(monitor: 0, config: config) == landing)
}

@MainActor @Test func aSlowReleaseReturnsToItsColumnWithoutWaitingForMomentum() {
    let manager = scrollingManager()
    let start = manager.world.viewPosition(monitor: 0, config: manager.config)
    manager.scrolled(.began)
    manager.scrolled(.changed(dx: -60, dy: 0, time: 1))
    manager.scrolled(.ended(time: 2))
    #expect(manager.swipe == nil)
    #expect(manager.world.viewPosition(monitor: 0, config: manager.config) == start)
}

@MainActor @Test func aNewSwipeStartsAtTheVisiblePositionOfAnUnfinishedGlide() {
    let manager = scrollingManager()
    let config = manager.config
    let before = manager.world.layout(config: config)[1]!.strip!
    manager.world.endSwipe(monitor: 0, coastingTo: 500, config: config)
    manager.targets = manager.world.layout(config: config)
    let target = manager.targets[1]!.strip!
    let now = CACurrentMediaTime()
    _ = manager.motion.move(1, from: before, to: target, monitor: 0, at: now,
                            springs: .init(position: .view, size: .view, slowdown: 1))
    let targetPosition = manager.world.viewPosition(monitor: 0, config: config)
    manager.scrolled(.began)
    #expect(manager.swipe!.origin < targetPosition - 100)
    manager.scrolled(.changed(dx: -4, dy: 0, time: now + 0.01))
    #expect(manager.world.viewPosition(monitor: 0, config: config) < targetPosition - 100)
}
