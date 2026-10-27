import AppKit
import Testing
import TegiCore
@testable import tegi

@MainActor private func focusManager(frontmostPID: @escaping () -> pid_t?) -> (WindowManager, AppWorker, [AXUIElement]) {
    _ = NSApplication.shared
    var config = Config.builtIn
    config.animations.on = false
    config.animations.windowServer = false
    config.focusRingWidth = 0
    let manager = WindowManager(config: config, frontmostPID: frontmostPID)
    let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: area, area: area)])
    let worker = AppWorker(.current) { _, _, _ in }
    let elements = [AXUIElementCreateSystemWide(), AXUIElementCreateApplication(getpid())]
    for (index, element) in elements.enumerated() {
        let id = index + 1
        let info = WindowInfo(windowID: 0, tileable: true, popup: false, floatable: true,
                              minimized: false, fullscreen: false, frame: area, title: "test")
        manager.wins[id] = Win(id: id, element: element, worker: worker, info: info, floating: false)
        manager.ids[element] = id
        manager.world.insert(id, config: config)
    }
    manager.focused = 2
    return (manager, worker, elements)
}

@MainActor @Test func anAcknowledgedColumnSwitchStillRejectsALateFocusEcho() {
    let (manager, worker, elements) = focusManager(frontmostPID: { getpid() })
    manager.expectFocus(2)
    manager.focusChanged(elements[1], worker)
    manager.focusChanged(elements[0], worker)
    #expect(manager.focused == 2)
    #expect(manager.world.focusedWindow == 2)
}

@MainActor @Test func backgroundFocusNotificationsCannotMoveTheStripButRealFocusCan() {
    var frontmost = getpid() + 1
    let (manager, worker, elements) = focusManager(frontmostPID: { frontmost })
    manager.focusChanged(elements[0], worker)
    #expect(manager.focused == 2)
    #expect(manager.world.focusedWindow == 2)
    frontmost = getpid()
    manager.focusChanged(elements[0], worker)
    #expect(manager.focused == 1)
    #expect(manager.world.focusedWindow == 1)
}
