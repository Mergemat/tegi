import CoreGraphics
import Testing
@testable import tegi

// A terminal expelled from a split column: tegi asks for the full height, the app keeps whole rows.
private let start = CGRect(x: 16, y: 583, width: 840, height: 518)
private let target = CGRect(x: 872, y: 49, width: 840, height: 1052)
private let rows = CGSize(width: 840, height: 1040)

@Test func aResizePictureLandsAtTheSizeTheAppTookNotTheOneAskedFor() {
    var size = ResizeFrames(from: start, start: start, target: target)
    size.accepted = rows
    #expect(size.frame(flying: target) == CGRect(origin: target.origin, size: rows))
}

@Test func aResizePictureStartsAsTheWindowReallyShowedAndFollowsTheSpring() {
    // The window had been refused a few points of its old height.
    let shown = CGRect(origin: start.origin, size: CGSize(width: 840, height: 510))
    let size = ResizeFrames(from: shown, start: start, target: target)
    #expect(size.frame(flying: start) == shown)
    let half = CGRect(x: 444, y: 316, width: 840, height: 785)
    let midway = size.frame(flying: half)
    #expect(midway.origin == half.origin)
    #expect(abs(midway.height - (510 + 0.5 * (1052 - 510))) < 0.001)
}
