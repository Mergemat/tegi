import AppKit
import Testing
import TegiCore
@testable import tegi

/// A window server that records commits and lets a test wait for the one it expects.
private final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var positions: [CGWindowID: CGPoint] = [:]
    private var commits: [[CGWindowID: CGPoint]] = []
    private let committed = DispatchSemaphore(value: 0)

    var driver: WindowServer.Driver {
        .init(bounds: { [self] id in lock.withLock { positions[id].map { CGRect(origin: $0, size: CGSize(width: 500, height: 500)) } } },
              submit: { [self] frames in
                  lock.withLock {
                      positions.merge(frames) { _, new in new }
                      commits.append(frames)
                  }
                  committed.signal()
              })
    }

    /// Waits for the compositor's next commit, as the display link delivers it.
    func nextCommit() -> [CGWindowID: CGPoint]? {
        guard committed.wait(timeout: .now() + 2) == .success else { return nil }
        return lock.withLock { commits.last }
    }

    func move(_ id: CGWindowID, to point: CGPoint) { lock.withLock { positions[id] = point } }
    func position(_ id: CGWindowID) -> CGPoint? { lock.withLock { positions[id] } }
}

@MainActor private func manager(_ server: Server) -> WindowManager {
    var config = Config.builtIn
    config.animations.windowServer = true
    let manager = WindowManager(config: config, windowServer: WindowServer(driver: server.driver))
    let element = AXUIElementCreateApplication(getpid())
    let worker = AppWorker(.current) { _, _, _ in }
    for (id, window) in [(1, CGWindowID(99)), (2, CGWindowID(98))] {
        let info = WindowInfo(windowID: window, tileable: true, floatable: true, minimized: false, fullscreen: false,
                              frame: CGRect(x: 0, y: 0, width: 500, height: 500), title: "test")
        manager.wins[id] = Win(id: id, element: element, worker: worker, info: info, floating: false)
    }
    manager.updateCompositor()
    return manager
}

@MainActor @Test func everyMoveInAFrameReachesTheWindowServerInOneTransaction() {
    let server = Server()
    let manager = manager(server)
    manager.compositor.place(1, at: CGPoint(x: 10, y: 20))
    manager.compositor.place(2, at: CGPoint(x: 30, y: 40))
    manager.compositor.place(1, at: CGPoint(x: 50, y: 60))
    var seen: [CGWindowID: CGPoint] = [:]
    while seen.count < 2, let commit = server.nextCommit() { seen.merge(commit) { _, new in new } }
    #expect(seen == [99: CGPoint(x: 50, y: 60), 98: CGPoint(x: 30, y: 40)])
}

@MainActor @Test func anOldAccessibilityWriteCannotPullAWindowOutOfANewerCompositorMove() {
    let server = Server()
    let manager = manager(server)
    let latest = CGPoint(x: 300, y: 100)
    manager.compositor.place(1, at: latest)
    #expect(server.nextCommit()?[99] == latest)
    // The app finishes an older Accessibility write, which puts the window back where it was.
    server.move(99, to: CGPoint(x: 100, y: 100))
    manager.generation[1] = 2
    manager.unlanded.insert(1)
    manager.placed(1, generation: 1)
    #expect(server.nextCommit()?[99] == latest)
    #expect(server.position(99) == latest)
    #expect(manager.unlanded.contains(1))
}
