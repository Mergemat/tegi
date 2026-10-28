import AppKit
import Testing
import TegiCore
@testable import tegi

private final class Server: @unchecked Sendable {
    private let lock = NSLock()
    private var content: [CGWindowID: CGRect] = [99: CGRect(x: 0, y: 0, width: 500, height: 500), 98: CGRect(x: 0, y: 0, width: 500, height: 500)]
    private var shown: [CGWindowID: WindowServer.Presentation] = [:]
    private var commits: [[CGWindowID: WindowServer.Presentation]] = []
    private var associated: [CGWindowID: [CGWindowID]] = [:]
    private var radii: [CGWindowID: Double] = [99: 16, 98: 16]
    private let committed = DispatchSemaphore(value: 0)

    var driver: WindowServer.Driver {
        .init(bounds: { [self] id in lock.withLock { content[id] } },
              placed: { [self] id in lock.withLock { shown[id]?.frame ?? content[id] } },
              submit: { [self] frames, released, synchronous in
                  lock.withLock {
                      for id in released { shown[id] = nil }
                      shown.merge(frames) { _, new in new }
                      if !synchronous { commits.append(frames) }
                  }
                  if !synchronous { committed.signal() }
              }, associated: { [self] id in lock.withLock { associated[id] ?? [] } },
              cornerRadius: { [self] id in lock.withLock { radii[id] } })
    }

    func nextCommit() -> [CGWindowID: WindowServer.Presentation]? {
        guard committed.wait(timeout: .now() + 2) == .success else { return nil }
        return lock.withLock { commits.removeFirst() }
    }
    func moveContent(_ id: CGWindowID, to point: CGPoint) { lock.withLock { content[id]?.origin = point } }
    func resizeContent(_ id: CGWindowID, to size: CGSize) { lock.withLock { content[id]?.size = size } }
    func setRadius(_ id: CGWindowID, _ radius: Double) { lock.withLock { radii[id] = radius } }
    func frame(_ id: CGWindowID) -> CGRect? {
        lock.withLock { shown[id].flatMap { $0.locksBounds ? $0.frame : content[id] } ?? content[id] }
    }
    func attach(_ child: CGWindowID, to parent: CGWindowID) {
        lock.withLock {
            content[child] = CGRect(x: 100, y: 100, width: 200, height: 100)
            associated[parent] = [child]
            associated[child] = [parent]
        }
    }
}

@MainActor private func manager(_ server: Server, authorized: Bool = true, popup: Bool = false) -> WindowManager {
    var config = Config.builtIn
    config.animations.windowServer = true
    let windowServer = WindowServer(driver: server.driver, settle: 0)
    windowServer.configure(enabled: true)
    if authorized { _ = windowServer.acceptAuthorization(connection: WindowServer.connectionID) }
    let manager = WindowManager(config: config, windowServer: windowServer)
    let element = AXUIElementCreateApplication(getpid())
    let worker = AppWorker(.current) { _, _, _ in }
    for (id, window) in [(1, CGWindowID(99)), (2, CGWindowID(98))] {
        let isPopup = popup && id == 2
        let info = WindowInfo(windowID: window, tileable: !isPopup, popup: isPopup, floatable: true, minimized: false, fullscreen: false,
                              frame: CGRect(x: 0, y: 0, width: 500, height: 500), title: "test")
        manager.wins[id] = Win(id: id, element: element, worker: worker, info: info, floating: isPopup)
    }
    manager.direct.update()
    return manager
}

@MainActor @Test func aTrackedPopupKeepsAppGeometryAcrossWorkspaceChanges() {
    let server = Server(), manager = manager(server, popup: true)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.world.pinned = [manager.activeWorkspaceID(on: 0)!]
    manager.wins[2]?.floatHome = manager.activeWorkspaceID(on: 0)
    manager.direct.update()
    server.moveContent(98, to: CGPoint(x: 600, y: 300))
    server.resizeContent(98, to: CGSize(width: 250, height: 200))
    let native = CGRect(x: 600, y: 300, width: 250, height: 200)
    #expect(manager.direct.heard(2))
    #expect(manager.direct.presented(2) == native)
    #expect(server.frame(98) == native)
    manager.world.perform(.focusWorkspaceDown, config: manager.config)
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 98)?.clip == .zero)
    server.moveContent(98, to: CGPoint(x: 700, y: 400))
    manager.world.perform(.focusWorkspaceUp, config: manager.config)
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 98)?.clip == screen)
    #expect(server.frame(98) == native.offsetBy(dx: 100, dy: 100))
    manager.direct.compositor.endAll()
    #expect(manager.windowServer.controlledWindows == 0)
}

@MainActor @Test func directMotionWithoutTheDocksGrantLeavesWindowsWhereTheyAre() {
    let server = Server(), manager = manager(server, authorized: false)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.world.insert(2, config: manager.config)
    manager.world.perform(.moveWindowToWorkspaceDown, config: manager.config)
    manager.relayout()
    #expect(manager.applied.isEmpty)
    #expect(manager.windowServer.controlledWindows == 0)
    #expect(manager.shownFrame(1, at: 0) == nil)
    #expect(manager.layout().values.contains { !$0.visible })
    manager.restore()
    #expect(manager.applied.isEmpty)
}

@MainActor @Test func aPresentationFrameIncludesSizeAndVisibility() {
    let server = Server(), manager = manager(server)
    let target = CGRect(x: 50, y: 60, width: 500, height: 500)
    manager.direct.compositor.place(1, frame: target, clip: .zero)
    manager.direct.compositor.place(2, frame: CGRect(x: 30, y: 40, width: 500, height: 500), clip: nil)
    var seen: [CGWindowID: WindowServer.Presentation] = [:]
    while seen.count < 2, let commit = server.nextCommit() { seen.merge(commit) { _, new in new } }
    #expect(seen[99]?.frame == target)
    #expect(seen[99]?.clip == .zero)
    #expect(seen[98]?.frame.origin == CGPoint(x: 30, y: 40))
}

@MainActor @Test func aLateAppWriteCannotMoveTheDisplayedWindow() {
    let server = Server(), manager = manager(server)
    let latest = CGRect(x: 300, y: 100, width: 500, height: 500)
    manager.direct.compositor.place(1, frame: latest, clip: nil)
    #expect(server.nextCommit()?[99]?.frame == latest)
    server.moveContent(99, to: CGPoint(x: 100, y: 100))
    manager.generation[1] = 2
    manager.unlanded.insert(1)
    manager.placed(1, generation: 1)
    #expect(server.frame(99) == latest)
    #expect(manager.unlanded.contains(1))
    manager.direct.compositor.release(1)
    #expect(server.frame(99)?.origin == CGPoint(x: 100, y: 100))
}

@MainActor @Test func handingWindowsBackRestoresNativeGeometryAndReleasesClips() {
    let server = Server(), manager = manager(server)
    manager.direct.compositor.place(1, frame: CGRect(x: -5000, y: 0, width: 500, height: 500), clip: .zero)
    #expect(server.nextCommit()?[99]?.clip == .zero)
    manager.direct.finish(restoring: [:])
    #expect(manager.windowServer.controlledWindows == 0)
    #expect(server.frame(99)?.origin == .zero)
}

@MainActor @Test func aWindowGoneFullScreenIsReleasedFromPresentationControl() {
    let server = Server(), manager = manager(server)
    manager.direct.compositor.place(1, frame: CGRect(x: 300, y: 100, width: 500, height: 500), clip: nil)
    #expect(server.nextCommit()?[99] != nil)
    manager.direct.unsynced.insert(1)
    manager.setFullScreen(manager.wins[1]!, true)
    #expect(manager.windowServer.presentation(of: 99) == nil)
    #expect(server.frame(99)?.origin == .zero)
    #expect(!manager.direct.unsynced.contains(1))
}

@MainActor @Test func aBusyOrFixedSizeAppIsNeverStretchedToFillItsTile() throws {
    let server = Server(), manager = manager(server)
    manager.world.monitors = [Monitor(id: 1, screen: CGRect(x: 0, y: 0, width: 1600, height: 1000), area: CGRect(x: 0, y: 0, width: 1600, height: 1000))]
    manager.direct.update()
    let target = CGRect(x: 50, y: 60, width: 800, height: 700)
    let now = CACurrentMediaTime()
    let spring = SpringParams(stiffness: 400)
    _ = manager.motion.move(1, from: CGRect(x: 0, y: 0, width: 500, height: 500), to: target, monitor: 0,
                            at: now - 10, springs: .init(position: spring, size: spring, slowdown: 1))
    let presented = try #require(server.nextCommit()?[99]?.frame)
    #expect(presented.origin == target.origin)
    #expect(presented.size == CGSize(width: 500, height: 500))
}

@MainActor @Test func onlyTheWindowBeingDraggedCanLeavePresentationControl() {
    let server = Server(), manager = manager(server)
    manager.nativePressed = 1
    #expect(!manager.direct.yieldToNative(2))
    #expect(manager.windowServer.presentation(of: 98) != nil)
    #expect(manager.direct.yieldToNative(1))
    #expect(manager.windowServer.presentation(of: 99) == nil)
    #expect(manager.nativeMoving == [1])
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 99) == nil)
    manager.nativePressed = nil
    manager.nativeDragEnded()
    #expect(manager.windowServer.presentation(of: 99) != nil)
}

@MainActor @Test func pauseAndMinimizeReleasePresentationAndResumeAcquiresItAgain() {
    let server = Server(), manager = manager(server)
    manager.setPaused(true)
    #expect(manager.windowServer.controlledWindows == 0)
    manager.direct.update()
    #expect(manager.windowServer.controlledWindows == 0)
    manager.setPaused(false)
    #expect(manager.windowServer.presentation(of: 99) != nil)
    manager.suspend(manager.wins[1]!, true)
    #expect(manager.windowServer.presentation(of: 99) == nil)
    manager.suspend(manager.wins[1]!, false)
    #expect(manager.windowServer.presentation(of: 99) != nil)
}

@MainActor @Test func aRefusedResizeStartsItsNextFlightAtTheSizeActuallyShown() throws {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 500 + 2 * manager.config.gap)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.world.perform(.setColumnWidth(.setFixed(500)), config: manager.config)
    manager.direct.update()
    let refused = CGRect(x: 100, y: 100, width: 800, height: 700)
    manager.motion.stop(1, at: (refused, 0))
    manager.direct.compositor.place(1, frame: refused, clip: screen)
    #expect(server.nextCommit()?[99]?.frame.size == CGSize(width: 500, height: 500))
    manager.relayout()
    let next = try #require(server.nextCommit()?[99])
    #expect(next.frame.size == CGSize(width: 500, height: 500))
    manager.motion.cancel()
    manager.direct.compositor.endAll()
}

@MainActor @Test func inactiveWindowsAreClippedBeforeTheirFirstCompositorFrame() {
    let server = Server(), manager = manager(server)
    manager.direct.compositor.endAll()
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 { manager.world.insert(id, config: manager.config) }
    manager.world.perform(.moveWindowToWorkspaceDown, config: manager.config)
    manager.world.perform(.focusWorkspaceUp, config: manager.config)
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 99)?.clip == screen)
    #expect(manager.windowServer.presentation(of: 98)?.clip == .zero)
    let inactive = manager.world.locate(2)!
    manager.wins[2]?.floating = true
    manager.wins[2]?.floatHome = manager.world.monitors[inactive.monitor].workspaces[inactive.workspace].id
    manager.floatHidden = []
    #expect(manager.direct.clip(2) == .zero)
}

@MainActor @Test(arguments: [false, true])
func workspaceSlidesPrepareIncomingContentWhileKeepingOutgoingWindowsVisible(reverse: Bool) {
    _ = NSApplication.shared
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 { manager.world.insert(id, config: manager.config) }
    manager.world.perform(.moveWindowToWorkspaceDown, config: manager.config)
    manager.world.perform(.focusWorkspaceUp, config: manager.config)
    manager.direct.update()
    let scene = Scene(area: screen.offsetBy(dx: -20000, dy: -20000), screen: screen,
                      wallpaper: nil, paper: nil, config: manager.config)
    defer { scene.close(); manager.direct.compositor.endAll() }
    manager.scenes[1] = scene
    scene.show([[], []], at: 0)
    scene.track(0.4)
    manager.world.perform(.focusWorkspaceDown, config: manager.config)
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 99)?.clip == screen)
    #expect(manager.windowServer.presentation(of: 98)?.clip == screen)
    if reverse {
        manager.world.perform(.focusWorkspaceUp, config: manager.config)
        manager.direct.update()
        #expect(manager.windowServer.presentation(of: 99)?.clip == screen)
        #expect(manager.windowServer.presentation(of: 98)?.clip == screen)
    }
    scene.hide()
    manager.direct.update()
    #expect(manager.windowServer.presentation(of: 99)?.clip == (reverse ? screen : .zero))
    #expect(manager.windowServer.presentation(of: 98)?.clip == (reverse ? .zero : screen))
}

@MainActor @Test func startupWorkspaceSwitchesDoNotShowAnUnloadedWallpaper() {
    _ = NSApplication.shared
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    let old = manager.activeWorkspaceID(on: 0)!
    manager.shown[1] = (old, 0)
    let scene = Scene(area: screen.offsetBy(dx: -20000, dy: -20000), screen: screen,
                      wallpaper: nil, paper: nil, config: manager.config)
    defer { scene.close(); manager.direct.compositor.endAll() }
    manager.scenes[1] = scene
    manager.world.perform(.focusWorkspaceDown, config: manager.config)
    manager.followWorkspaces(animate: true)
    #expect(!scene.isVisible)
}

@MainActor @Test func anOutgoingWorkspaceCannotBeExposedByAnUnfinishedFlight() {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.direct.update()
    let params = SpringParams(stiffness: 400)
    _ = manager.motion.move(1, from: CGRect(x: 0, y: 0, width: 500, height: 500),
                            to: CGRect(x: 600, y: 0, width: 500, height: 500), monitor: 0,
                            at: CACurrentMediaTime(), springs: .init(position: params, size: params, slowdown: 1))
    #expect(server.nextCommit()?[99]?.clip == screen)
    manager.world.perform(.focusWorkspaceDown, config: manager.config)
    manager.direct.update()
    _ = manager.motion.move(1, from: .zero,
                            to: CGRect(x: 600, y: 0, width: 700, height: 500), monitor: 0,
                            at: CACurrentMediaTime(), springs: .init(position: params, size: params, slowdown: 1))
    var next: WindowServer.Presentation?
    while let commit = server.nextCommit() {
        guard commit[99]?.resizeTo?.width == 700 else { continue }
        next = commit[99]
        break
    }
    #expect(next != nil)
    #expect(next?.clip == .zero)
    manager.motion.cancel()
    manager.direct.compositor.endAll()
}

@MainActor @Test func anAttachedWindowIsControlledAndReportedBeforeAccessibilityDiscoversIt() {
    let server = Server(), manager = manager(server)
    var reported = manager.windowServer.controlledWindows
    manager.onChange = { reported = manager.windowServer.controlledWindows }
    server.attach(100, to: 99)
    manager.familyChanged()
    #expect(manager.windowServer.presentation(of: 100)?.clip == .zero)
    #expect(reported == 3)
    manager.onChange = {}
    manager.direct.compositor.endAll()
}

@MainActor @Test func livePreviewsFollowPresentedGeometryWhenAnAppRefusesItsTileSize() throws {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.direct.update()
    let preview = try #require(manager.sceneContent(0, current: true).flatMap { $0 }.first { $0.id == 1 })
    #expect(preview.frame.size == CGSize(width: 500, height: 500))
    let target = CGRect(x: 100, y: 60, width: 800, height: 700)
    manager.homes[1] = manager.world.monitors[0].workspaces[0].id
    _ = manager.motion.move(1, from: CGRect(x: 20, y: 20, width: 600, height: 600), to: target, monitor: 0,
                            at: CACurrentMediaTime() - 10, springs: .init(position: .view, size: .view, slowdown: 1))
    let presented = try #require(server.nextCommit()?[99]?.frame)
    let flying = try #require(manager.sceneContent(0, current: true).flatMap { $0 }.first { $0.id == 1 })
    #expect(flying.frame == presented)
    manager.motion.cancel()
    manager.direct.compositor.endAll()
}

@MainActor @Test func aSizeAnswerRefreshesPresentationWithoutAnotherLayoutAction() throws {
    let server = Server(), manager = manager(server)
    let target = CGRect(x: 100, y: 60, width: 800, height: 700)
    manager.direct.compositor.place(1, frame: target, clip: nil)
    #expect(server.nextCommit()?[99]?.frame.size == CGSize(width: 500, height: 500))
    manager.generation[1] = 1
    manager.unlanded.insert(1)
    server.resizeContent(99, to: target.size)
    manager.placed(1, generation: 1)
    #expect(manager.windowServer.presentation(of: 99)?.frame == target)
}

@MainActor @Test func cornerGeometryAnswersUpdateBothTheNativeOutlineAndWorkspacePreview() throws {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    manager.world.insert(1, config: manager.config)
    manager.wins[1]?.nativeRadius = 16
    server.setRadius(99, 28)
    manager.contentAnswered(1)
    #expect(manager.cornerRadius(1) == 28)
    #expect(try #require(manager.sceneContent(0).first?.first).radius == 28)
    manager.config.windowCornerRadius = 12
    #expect(manager.cornerRadius(1) == 12)
    #expect(try #require(manager.sceneContent(0).first?.first).radius == 12)
    manager.ring.update([], tabs: [], config: manager.config)
    manager.direct.compositor.endAll()
}

@MainActor @Test func aRefusedHeightReflowsTheStackWhileItIsStillMoving() throws {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 {
        manager.world.insert(id, config: manager.config)
        manager.motion.stop(id, at: (CGRect(x: 0, y: 0, width: 500, height: 500), 0))
    }
    manager.world.perform(.consumeOrExpelWindowLeft, config: manager.config)
    manager.relayout()
    let asked = try #require(manager.targets[1]?.frame).size
    #expect(manager.motion.isFlying(1))
    manager.sizeAnswered(1, asked: asked, actual: CGSize(width: asked.width, height: 500))
    let frames = manager.world.layout(config: manager.config)
    #expect(frames[1]?.frame.height == 500)
    #expect(frames[2]?.frame.minY == frames[1]!.frame.maxY + CGFloat(manager.config.gap))
    #expect(frames[2]?.frame.maxY == 784)
    manager.motion.cancel()
    manager.direct.compositor.endAll()
}

@MainActor @Test(arguments: ["paused", "dragging", "fullscreen"])
func aLateSizeAnswerCannotReflowAWindowOutsideTilingControl(state: String) throws {
    let server = Server(), manager = manager(server)
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 { manager.world.insert(id, config: manager.config) }
    manager.world.perform(.consumeOrExpelWindowLeft, config: manager.config)
    let before = manager.world.layout(config: manager.config)
    let asked = try #require(before[1]?.frame).size
    switch state {
    case "paused": manager.paused = true
    case "dragging": manager.nativeMoving.insert(1)
    default: manager.wins[1]?.fullScreen = true
    }
    manager.sizeAnswered(1, asked: asked, actual: CGSize(width: asked.width, height: 500))
    #expect(manager.world.layout(config: manager.config) == before)
    #expect(manager.world.heightLimit(for: 1) == nil)
    manager.direct.compositor.endAll()
}

@MainActor @Test func theFocusOutlineFollowsTheLastServerFrameWithoutAnotherAction() async throws {
    let server = Server(), manager = manager(server)
    let display = try #require(manager.displays().first)
    manager.world.setDisplays([display], config: manager.config)
    manager.world.insert(1, config: manager.config)
    manager.focused = 1
    manager.direct.update()
    let initial = CGRect(x: 40, y: 60, width: 500, height: 500)
    manager.direct.compositor.place(1, frame: initial, clip: display.screen)
    #expect(server.nextCommit()?[99]?.frame == initial)
    manager.updateRing(at: 0)
    #expect(manager.ring.frame(on: display.id) == initial)
    let target = CGRect(x: 80, y: 60, width: 800, height: 700)
    server.resizeContent(99, to: target.size)
    let caughtUp = await withCheckedContinuation { continuation in
        var finished = false
        manager.onChange = {
            guard !finished, manager.ring.frame(on: display.id) == target else { return }
            finished = true
            continuation.resume(returning: true)
        }
        manager.direct.compositor.place(1, frame: target, clip: display.screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !finished else { return }
            finished = true
            continuation.resume(returning: false)
        }
    }
    #expect(caughtUp)
    #expect(manager.ring.frame(on: display.id) == target)
    manager.onChange = {}
    manager.direct.compositor.endAll()
    manager.ring.update([], tabs: [], config: manager.config)
}

@MainActor @Test func scrollBurstsCannotScheduleTheReleaseBeyondTheNextDisplayFrame() throws {
    let server = Server(), manager = manager(server)
    defer {
        manager.motion.cancel()
        manager.ring.update([], tabs: [], config: manager.config)
        manager.direct.compositor.endAll()
    }
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 { manager.world.insert(id, config: manager.config) }
    manager.world.perform(.focusColumnFirst, config: manager.config)
    manager.relayout(direct: true)
    var released: Flight?
    let publish = manager.motion.onFlights
    manager.motion.onFlights = { flights in released = flights[1]; publish(flights) }
    manager.scrolled(.began)
    for step in 1...40 {
        manager.scrolled(.changed(dx: -5, dy: 0, time: 1 + Double(step) / 240))
    }
    manager.scrolled(.ended(time: 1.18))
    let nextFrame = CACurrentMediaTime() + 1 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
    let start = try #require(released?.x.start)
    #expect(start <= nextFrame)
    #expect(manager.motion.clock <= nextFrame)
}

@MainActor @Test(arguments: [false, true], [40, 2400])
func queuedScrollSamplesPublishOnlyTheLatestWholeStrip(released: Bool, samples: Int) async throws {
    let server = Server(), manager = manager(server)
    defer {
        manager.swipe = nil
        manager.motion.cancel()
        manager.ring.update([], tabs: [], config: manager.config)
        manager.direct.compositor.endAll()
    }
    manager.config.defaultColumnWidth = 0.8
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)
    manager.world = World(monitors: [Monitor(id: 1, screen: screen, area: screen)])
    for id in 1...2 { manager.world.insert(id, config: manager.config) }
    manager.world.perform(.focusColumnFirst, config: manager.config)
    manager.relayout(direct: true)
    manager.scrolled(.began)
    var plans: [[WindowID: Flight]] = []
    let publish = manager.motion.onFlights
    manager.motion.onFlights = { flights in plans.append(flights); publish(flights) }
    for step in 1...samples {
        let dx = (step - 1) % 80 < 40 ? -5.0 : 5.0
        manager.scrolled(.changed(dx: dx, dy: 0, time: 1 + Double(step) / 240))
    }
    let tracker = try #require(manager.swipe?.tracker)
    #expect(tracker.position == (samples == 40 ? 200 : 0))
    #expect(abs(abs(tracker.velocity) - 1200) < 0.001)
    if released { manager.scrolled(.ended(time: 1 + Double(samples) / 240 + 0.015)) }
    let expected = manager.world.layout(config: manager.config)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(!plans.isEmpty)
    let wholeLatestStrip = plans.allSatisfy { plan in
        [1, 2].allSatisfy { plan[$0]?.target == expected[$0]?.strip }
    }
    #expect(wholeLatestStrip)
    if released {
        #expect(manager.swipe == nil)
        #expect(plans.allSatisfy { $0.values.allSatisfy { $0.x.params != .tracking } })
    }
}
