import CoreGraphics
import Testing
@testable import tegi

private final class Server {
    var positions: [UInt32: CGPoint] = [1: .zero, 2: .zero]
    var commits = 0
    var refuses = false

    var driver: WindowServer.Driver {
        .init(bounds: { id in self.positions[id].map { CGRect(origin: $0, size: CGSize(width: 100, height: 100)) } },
              submit: { frames in
                  self.commits += 1
                  if !self.refuses { self.positions.merge(frames) { _, new in new } }
              })
    }
}

@Test func aSilentDenialStopsSubmittingUntilTurnedOnAgain() {
    let server = Server()
    server.refuses = true
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.configure(enabled: true)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    motion.submit([1: CGPoint(x: 50, y: 60), 2: CGPoint(x: 70, y: 80)])
    #expect(!motion.active)
    #expect(motion.failure != nil)
    motion.submit([1: CGPoint(x: 90, y: 100)])
    #expect(server.commits == 1)
    motion.configure(enabled: false)
    motion.configure(enabled: true)
    server.refuses = false
    motion.submit([1: CGPoint(x: 90, y: 100)])
    #expect(motion.active)
    #expect(server.positions[1] == CGPoint(x: 90, y: 100))
}

@Test func untilTheDockGrantsItMovesNothing() {
    let server = Server()
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.configure(enabled: true)
    #expect(motion.wanted && !motion.active)
    motion.submit([1: CGPoint(x: 50, y: 60)])
    #expect(server.commits == 0)
    _ = motion.acceptAuthorization(connection: WindowServer.connectionID)
    motion.submit([1: CGPoint(x: 50, y: 60)])
    #expect(server.positions[1] == CGPoint(x: 50, y: 60))
}

@Test func turnedOffItMovesNothing() {
    let server = Server()
    let motion = WindowServer(driver: server.driver, settle: 0)
    motion.submit([1: CGPoint(x: 50, y: 60)])
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
