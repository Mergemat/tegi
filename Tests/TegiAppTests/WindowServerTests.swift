import AppKit
import QuartzCore
import Testing
@testable import tegi

private final class Server {
    var positions: [UInt32: CGPoint] = [1: .zero, 2: .zero]
    var commits = 0
    var refuses = false

    var driver: WindowServer.Driver {
        .init(bounds: { id in self.positions[id].map { CGRect(origin: $0, size: CGSize(width: 100, height: 100)) } },
              submit: { frames, _, _ in
                  self.commits += 1
                  if !self.refuses { self.positions.merge(frames.mapValues { $0.frame.origin }) { _, new in new } }
              })
    }
}

@Test func aSilentDenialStopsSubmittingUntilTurnedOnAgain() {
    let server = Server()
    server.refuses = true
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.configure(enabled: true)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil), 2: .init(frame: CGRect(x: 70, y: 80, width: 100, height: 100), clip: nil)])
    #expect(!motion.active)
    #expect(motion.failure != nil)
    motion.submit([1: .init(frame: CGRect(x: 90, y: 100, width: 100, height: 100), clip: nil)])
    #expect(server.commits == 1)
    motion.configure(enabled: false)
    motion.configure(enabled: true)
    server.refuses = false
    motion.submit([1: .init(frame: CGRect(x: 90, y: 100, width: 100, height: 100), clip: nil)])
    #expect(motion.active)
    #expect(server.positions[1] == CGPoint(x: 90, y: 100))
}

@Test func untilTheDockGrantsItMovesNothing() {
    let server = Server()
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.configure(enabled: true)
    #expect(motion.wanted && !motion.active)
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil)])
    #expect(server.commits == 0)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil)])
    #expect(server.positions[1] == CGPoint(x: 50, y: 60))
}

@Test func turnedOffItMovesNothing() {
    let server = Server()
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil)])
    #expect(server.positions[1] == .zero)
    #expect(server.commits == 0)
}

@Test func authorizationBelongsToOneProcessAndTurningMotionOffHidesLivePreviews() {
    let server = Server()
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.configure(enabled: true)
    #expect(!motion.acceptAuthorization(connection: WindowServer.connectionID + 1))
    #expect(!motion.liveScenes)
    #expect(motion.acceptAuthorization(connection: WindowServer.connectionID))
    #expect(motion.liveScenes)
    motion.configure(enabled: false)
    #expect(!motion.liveScenes)
    #expect(!motion.active)
}

@Test func aDenialIsCaughtEvenWhenANewerMoveOvertakesTheOneBeingChecked() {
    let server = Server()
    server.refuses = true
    let motion = WindowServer(driver: server.driver, settle: 0.02)
    motion.configure(enabled: true)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    let refused = DispatchSemaphore(value: 0)
    motion.onRefused = { refused.signal() }
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil)])
    motion.submit([1: .init(frame: CGRect(x: 70, y: 80, width: 100, height: 100), clip: nil)])
    #expect(refused.wait(timeout: .now() + 1) == .success)
}

@Test func aWindowItsAppMovesAfterAnAcceptedMoveIsNotARefusal() {
    var reads = 0
    let driver = WindowServer.Driver(bounds: { _ in
        reads += 1
        // The first read picks the window to check, still at rest; by the check, the app has taken it over, resizing it
        // from somewhere else.
        return CGRect(origin: reads == 1 ? .zero : CGPoint(x: 400, y: 60), size: CGSize(width: 100, height: 100))
    }, submit: { _, _, _ in })
    let motion = WindowServer(driver: driver, settle: 0)
    motion.configure(enabled: true)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    motion.submit([1: .init(frame: CGRect(x: 50, y: 60, width: 100, height: 100), clip: nil)])
    #expect(motion.failure == nil)
}

@Test func attachedWindowsFollowTheirParentsPresentationAndVisibility() {
    var native: [UInt32: CGRect] = [1: CGRect(x: 100, y: 100, width: 800, height: 600),
                                  2: CGRect(x: 300, y: 200, width: 400, height: 200)]
    var shown: [UInt32: WindowServer.Presentation] = [:]
    var associated: [UInt32] = [2]
    let driver = WindowServer.Driver(bounds: { native[$0] },
                                    placed: { shown[$0]?.frame ?? native[$0] },
                                    submit: { frames, released, _ in
        for id in released { shown[id] = nil }
        shown.merge(frames) { _, new in new }
    }, associated: { $0 == 1 ? associated : (associated.isEmpty ? [] : [1]) })
    let server = WindowServer(driver: driver, settle: 0)
    server.configure(enabled: true)
    _ = server.acceptAuthorization(connection: WindowServer.connectionID)
    server.manage([1, 2])
    server.submit([1: .init(frame: CGRect(x: 500, y: 300, width: 400, height: 300), clip: .zero, resizeTo: CGSize(width: 800, height: 600))])
    #expect(shown[2]?.frame == CGRect(x: 600, y: 350, width: 200, height: 100))
    #expect(shown[2]?.clip == .zero)
    server.submit([2: .init(frame: CGRect(x: 0, y: 0, width: 400, height: 200), clip: nil)])
    #expect(shown[2]?.frame == CGRect(x: 600, y: 350, width: 200, height: 100))
    // The app redraws at a new native size. The next frame retains the requested presentation.
    native[1]?.size = CGSize(width: 400, height: 300)
    server.submit([1: .init(frame: CGRect(x: 500, y: 300, width: 400, height: 300), clip: nil)])
    #expect(shown[2]?.frame == CGRect(x: 700, y: 400, width: 400, height: 200))
    associated = []
    server.manage([1])
    #expect(shown[2] == nil)
    server.configure(enabled: false)
    #expect(shown.isEmpty)
    #expect(server.controlledWindows == 0)
}

@MainActor @Test func nativeRedrawCannotChangeLockedPresentationAndReleaseRestoresIt() async throws {
    _ = NSApplication.shared
    let driver = try #require(WindowServer.Driver.load())
    let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 150), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    CATransaction.flush()
    let id = CGWindowID(window.windowNumber)
    let child = NSWindow(contentRect: CGRect(x: -19950, y: -19950, width: 100, height: 80), styleMask: .titled, backing: .buffered, defer: false)
    child.isReleasedWhenClosed = false
    window.addChildWindow(child, ordered: .above)
    child.orderFront(nil)
    CATransaction.flush()
    let childID = CGWindowID(child.windowNumber)
    let ready = DisplayFrame()
    await ready.next()
    #expect(driver.associated(id).contains(childID))
    #expect(driver.associated(childID).contains(id))
    let server = WindowServer(driver: driver, settle: 0)
    server.configure(enabled: true)
    _ = server.acceptAuthorization(connection: WindowServer.connectionID)
    defer { server.releaseAll(); child.close(); window.close() }
    server.manage([id, childID])
    let target = CGRect(x: -10000, y: -10000, width: 500, height: 400)
    let nativeSize = try #require(server.contentBounds(of: id)?.size)
    server.submit([id: .init(frame: target, clip: .zero, resizeTo: target.size)])
    server.manage([id, childID])
    #expect(windowBounds(id)?.size == nativeSize)
    server.submit([id: .init(frame: target, clip: .zero, resizeTo: server.contentBounds(of: id)?.size)])
    server.manage([id, childID])
    #expect(windowBounds(id) == target)
    #expect(server.presentation(of: childID)?.clip == .zero)
    window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: 300, height: 220)), display: true)
    window.displayIfNeeded()
    CATransaction.flush()
    let frame = DisplayFrame()
    await frame.next()
    #expect(server.contentBounds(of: id)?.size == CGSize(width: 300, height: 220))
    #expect(windowBounds(id) == target)
    server.releaseAll()
    let restored = try #require(windowBounds(id))
    // WindowServer excludes transparent decoration edges; their inset changes with native activation state.
    #expect(abs(restored.width - 300) <= 4)
    #expect(abs(restored.height - 220) <= 4)
}

@MainActor private final class DisplayFrame: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?
    func next() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            link = NSScreen.main?.displayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        self.link = nil
        continuation?.resume()
        continuation = nil
    }
}

@Test func aFullscreenOrDraggedFamilyMemberCannotBeTakenBackThroughItsSibling() {
    let native = CGRect(x: 0, y: 0, width: 500, height: 500)
    var shown: [UInt32: WindowServer.Presentation] = [:]
    let driver = WindowServer.Driver(bounds: { _ in native }, submit: { frames, released, _ in
        for id in released { shown[id] = nil }
        shown.merge(frames) { _, new in new }
    }, associated: { _ in [1, 2] })
    let server = WindowServer(driver: driver, settle: 0)
    server.configure(enabled: true)
    _ = server.acceptAuthorization(connection: WindowServer.connectionID)
    server.manage([1, 2])
    server.release([1])
    server.manage([2], excluding: [1])
    server.submit([2: .init(frame: native, clip: .zero)])
    #expect(shown[1] == nil)
    #expect(shown[2]?.clip == .zero)
    server.release([2])
    server.submit([2: .init(frame: native, clip: nil)])
    #expect(shown.isEmpty)
}
