import Testing
@testable import TegiCore

// A window picture's alpha: opaque inside a rectangle with circular corners of radius r.
private func rounded(_ w: Int, _ h: Int, _ r: Double) -> (Int, Int) -> UInt8 {
    { x, y in
        let px = Double(x) + 0.5, py = Double(y) + 0.5
        let cx = min(max(px, r), Double(w) - r), cy = min(max(py, r), Double(h) - r)
        return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r ? 255 : 0
    }
}

@Test func aWindowsCornerRadiusIsReadFromItsPicture() {
    for r in [10.0, 16, 26, 32] {
        let measured = Corners.radius(width: 400, height: 300, alpha: rounded(400, 300, r))
        #expect(abs((measured ?? 0) - r) <= 1.5, "radius \(r) measured \(String(describing: measured))")
    }
}

@Test func squareWindowsHaveNoRadiusAndBlankPicturesNoAnswer() {
    #expect(Corners.radius(width: 200, height: 100, alpha: { _, _ in 255 }) == 0)
    #expect(Corners.radius(width: 200, height: 100, alpha: { _, _ in 0 }) == nil)
}

@Test func seeThroughWindowsAreNotMistakenForRoundOnes() {
    // A translucent terminal: mostly clear, with an opaque line of text near the top.
    let terminal: (Int, Int) -> UInt8 = { x, y in y == 30 && x < 40 ? 255 : 0 }
    #expect(Corners.radius(width: 400, height: 300, alpha: terminal) == nil)
}

@Test func aFullyClearPictureIsBlankButAnyContentIsNot() {
    #expect(Corners.isBlank(width: 400, height: 300) { _, _ in 0 })
    #expect(!Corners.isBlank(width: 400, height: 300, alpha: rounded(400, 300, 16)))
    // A small opaque patch, like a lone button on a clear window, still counts as content.
    #expect(!Corners.isBlank(width: 400, height: 300) { x, y in (200..<230).contains(x) && (150..<170).contains(y) ? 255 : 0 })
}
