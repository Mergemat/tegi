import AppKit
import QuartzCore
import Testing
import TegiCore
@testable import tegi

@MainActor private func standardWindow() throws -> (NSWindow, WindowManager, CGRect) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 300, height: 200),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.orderFront(nil)
    CATransaction.flush()
    let id = CGWindowID(window.windowNumber)
    let native = try #require(windowBounds(id))
    var config = Config.builtIn
    config.animations.windowServer = false
    config.focusRingWidth = 0
    let manager = WindowManager(config: config)
    let area = CGRect(x: native.minX - 16, y: native.minY - 16, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: area, area: area)])
    manager.world.insert(1, config: config)
    let worker = AppWorker(.current) { _, _, _ in }
    let info = WindowInfo(windowID: id, tileable: true, popup: false, floatable: true, minimized: false,
                          fullscreen: false, frame: native, title: "test")
    manager.wins[1] = Win(id: 1, element: AXUIElementCreateApplication(getpid()), worker: worker, info: info, floating: false)
    manager.targets = manager.world.layout(config: config)
    return (window, manager, native)
}

@MainActor @Test func standardMotionKeepsFollowingNativeGeometryAfterTheSpringEnds() throws {
    let (window, manager, native) = try standardWindow()
    defer { window.close() }
    let target = try #require(manager.targets[1]?.strip)
    let now = CACurrentMediaTime()
    _ = manager.motion.move(1, from: native, to: target, monitor: 0, at: now - 10,
                            springs: .init(position: .view, size: .view, slowdown: 1))
    _ = manager.motion.frames(at: now)
    manager.unlanded.insert(1)
    #expect(!manager.motion.isMoving)
    #expect(manager.shownFrame(1, at: now) == native)
}

@MainActor @Test func aNewStandardFlightStartsAtTheFrameTheAppIsStillShowing() throws {
    let (window, manager, native) = try standardWindow()
    defer { manager.motion.cancel(); window.close() }
    let previous = try #require(manager.targets[1]?.strip)
    manager.motion.stop(1, at: (previous, 0))
    manager.applied[1] = previous
    manager.unlanded.insert(1)
    manager.world.perform(.setColumnWidth(.setFixed(700)), config: manager.config)
    manager.relayout()
    #expect(manager.motion.current(1, at: 0)?.frame == native)
}

@MainActor @Test func theOverviewStartsAtVisibleStandardWindowGeometry() throws {
    let (window, manager, native) = try standardWindow()
    defer { window.close() }
    let area = manager.world.monitors[0].area
    let preview = try #require(manager.sceneContent(0, current: true).first?.first)
    #expect(preview.frame == native.offsetBy(dx: -area.minX, dy: -area.minY))
}

@MainActor @Test func standardStateReportsTheFrameActuallyOnScreen() throws {
    let (window, manager, native) = try standardWindow()
    defer { window.close() }
    let monitors = try #require(manager.state()["monitors"] as? [[String: Any]])
    let workspaces = try #require(monitors.first?["workspaces"] as? [[String: Any]])
    let columns = try #require(workspaces.first?["columns"] as? [[[String: Any]]])
    let reported = try #require(columns.first?.first)
    #expect(reported["presented_frame"] as? [CGFloat] == [native.minX, native.minY, native.width, native.height])
}

@MainActor @Test func standardOverflowParksTheUpperWindowAndKeepsTheStackGrouped() throws {
    let (window, manager, _) = try standardWindow()
    defer { window.close() }
    manager.world.insert(2, config: manager.config)
    manager.world.perform(.consumeOrExpelWindowLeft, config: manager.config)
    for id in 1...2 {
        let asked = try #require(manager.world.layout(config: manager.config)[id]?.frame.size)
        _ = manager.world.observeSize(CGSize(width: asked.width, height: 500), asked: asked, for: id)
    }
    let lower = manager.layout()
    #expect(lower[1]?.visible == false)
    #expect(lower[1]?.strip == nil)
    #expect(lower[2]?.visible == true)
    #expect(manager.world.monitors[0].workspaces[0].columns.first?.windows == [1, 2])
    manager.world.perform(.focusWindowUp, config: manager.config)
    #expect(manager.layout()[1]?.visible == true)
}
