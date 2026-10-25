import CoreGraphics
import Testing
@testable import TegiCore

@Test func aWindowThatStaysShorterIsDrawnAtTheSizeItTook() {
    // QuickTime keeps its video's shape: asked for a full-height column, it stays shorter.
    let kept = Refusal(asked: CGSize(width: 700, height: 1000), got: CGSize(width: 700, height: 460))
    #expect(kept.apply(to: CGRect(x: 40, y: 30, width: 700, height: 1000)) == CGRect(x: 40, y: 30, width: 700, height: 460))
    // A new size is a new ask: until the app answers it, the frame is as laid out.
    #expect(kept.apply(to: CGRect(x: 40, y: 30, width: 900, height: 1000)) == CGRect(x: 40, y: 30, width: 900, height: 1000))
    // Moving a window doesn't change what it agreed to.
    #expect(kept.apply(to: CGRect(x: 800, y: 30, width: 700, height: 1000)).height == 460)
}
