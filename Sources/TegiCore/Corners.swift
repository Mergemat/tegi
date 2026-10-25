import Foundation

public enum Corners {
    /// The corner radius of a window, in the picture's pixels, read from the transparency of its top-left corner.
    /// The cut-out of a corner of radius r covers r²(1 − π/4), so counting it gives r without tracing the curve.
    public static func radius(width: Int, height: Int, alpha: (Int, Int) -> UInt8) -> Double? {
        let side = min(width, height) / 4
        guard side > 0 else { return nil }
        // A rounded corner ends inside the sampled square, so its far row and column are solid; a see-through window's aren't.
        let edge = side - 1
        guard (0..<side).allSatisfy({ alpha($0, edge) >= 128 && alpha(edge, $0) >= 128 }) else { return nil }
        var clear = 0
        for y in 0..<side {
            for x in 0..<side where alpha(x, y) < 128 { clear += 1 }
        }
        guard clear < side * side else { return nil }
        return (Double(clear) / (1 - .pi / 4)).squareRoot()
    }

    /// Whether a window's picture shows nothing at all, like the invisible helper windows some apps keep.
    /// Every eighth pixel each way is enough to catch even a lone button.
    public static func isBlank(width: Int, height: Int, alpha: (Int, Int) -> UInt8) -> Bool {
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) where alpha(x, y) > 8 { return false }
        }
        return true
    }
}
