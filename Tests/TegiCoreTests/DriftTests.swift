import CoreGraphics
import Testing
@testable import TegiCore

private let laidOut = CGRect(x: 864, y: 49, width: 554, height: 1052)

@Test func aWindowAnAppMovedItselfGoesBack() {
    // Telegram restoring its saved frame just after it opens.
    #expect(Drift.strayed(laidOut.insetBy(dx: 0, dy: -14).offsetBy(dx: 0, dy: -12), from: laidOut, refusal: nil))
    #expect(!Drift.strayed(laidOut.offsetBy(dx: 0.5, dy: 0), from: laidOut, refusal: nil))
}

@Test func aSizeTheAppAlreadyKeptIsNotAStray() {
    let kept = Refusal(asked: laidOut.size, got: CGSize(width: 554, height: 460))
    #expect(!Drift.strayed(CGRect(origin: laidOut.origin, size: kept.got), from: laidOut, refusal: kept))
    #expect(Drift.strayed(CGRect(origin: CGPoint(x: 0, y: 49), size: kept.got), from: laidOut, refusal: kept))
}

@Test func anAppThatKeepsMovingItsWindowIsLeftAlone() {
    var drift = Drift()
    let answers = [0, 0.5, 1, 1.5, 4].map { drift.allow(at: $0) }
    #expect(answers == [true, true, true, false, true])
}
