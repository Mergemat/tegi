import CoreGraphics

/// The size an app took when tegi asked for another, like a video player keeping its video's shape.
public struct Refusal: Equatable {
    public var asked: CGSize
    public var got: CGSize

    public init(asked: CGSize, got: CGSize) {
        self.asked = asked
        self.got = got
    }

    /// The window as it really sits, for a frame of the size that was asked: same top-left corner, the size it took.
    public func apply(to frame: CGRect) -> CGRect {
        guard abs(frame.width - asked.width) <= 1, abs(frame.height - asked.height) <= 1 else { return frame }
        return CGRect(origin: frame.origin, size: got)
    }
}
