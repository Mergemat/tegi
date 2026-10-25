import AppKit
import QuartzCore

/// A workspace's label in the overview: its number on a small gummy key, and its name beside it.
final class WorkspaceTag: CALayer {
    private let body = CALayer()
    private let base = CALayer()
    private let key = CAGradientLayer()
    private let number = CATextLayer()
    private let title = CATextLayer()
    private static let side = 20.0, rise = 2.0
    private static let numberFont = rounded(11.5, .heavy)
    private static let nameFont = rounded(12.5, .semibold)

    init(scale: CGFloat) {
        super.init()
        anchorPoint = .zero
        base.cornerRadius = 7
        base.frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        key.cornerRadius = 7
        key.frame = CGRect(x: 0, y: Self.rise, width: Self.side, height: Self.side)
        key.startPoint = CGPoint(x: 0.5, y: 1)
        key.endPoint = CGPoint(x: 0.5, y: 0)
        for (text, font) in [(number, Self.numberFont), (title, Self.nameFont)] {
            text.font = font
            text.fontSize = font.pointSize
            text.contentsScale = scale
            text.foregroundColor = .white
        }
        number.alignmentMode = .center
        // Keeps the name readable over any wallpaper.
        title.shadowOpacity = 0.4
        title.shadowRadius = 3
        title.shadowOffset = .zero
        [base, key, number, title].forEach(body.addSublayer)
        addSublayer(body)
        set(active: false)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func set(number n: Int, name text: String?) {
        number.string = "\(n)"
        let digits = ("\(n)" as NSString).size(withAttributes: [.font: Self.numberFont])
        number.frame = CGRect(x: 0, y: Self.rise + (Self.side - ceil(digits.height)) / 2, width: Self.side, height: ceil(digits.height))
        title.string = text ?? ""
        let size = ((text ?? "") as NSString).size(withAttributes: [.font: Self.nameFont])
        title.frame = CGRect(x: Self.side + 7, y: Self.rise + (Self.side - ceil(size.height)) / 2, width: ceil(size.width) + 2, height: ceil(size.height))
        bounds = CGRect(x: 0, y: 0, width: text == nil ? Self.side : title.frame.maxX, height: Self.side + Self.rise)
    }

    private var active: Bool?

    func set(active: Bool) {
        guard active != self.active else { return }
        self.active = active
        key.colors = active ? [cg(0x8fd0ff), cg(0x5aa8ff)] : [CGColor(gray: 1, alpha: 0.2), CGColor(gray: 1, alpha: 0.16)]
        base.backgroundColor = active ? cg(0x2f6fd6) : CGColor(gray: 0, alpha: 0.3)
        body.opacity = active ? 1 : 0.65
    }

    private func cg(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, alpha: 1)
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
