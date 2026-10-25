// Draws the sharing images from the artwork in Resources/brand:
//   og.png      1280×640, GitHub's social preview (Settings → Social preview)
//   social.png  1200×1200, for posting elsewhere
// Run from the repository root: swift scripts/social.swift
import AppKit

let brand = "Resources/brand/"
let ink = NSColor(srgbRed: 0.96, green: 0.97, blue: 1, alpha: 1)
let soft = NSColor(srgbRed: 0.72, green: 0.75, blue: 0.92, alpha: 1)
let blue = NSColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 1)
let command = "brew install mergemat/tap/tegi"

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

func attributed(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
}

func render(_ name: String, width: Int, height: Int, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: brand + name))
    print("Wrote \(brand + name)")
}

// The title, tagline and install command, stacked and aligned on x (or centered on it).
func block(_ cg: CGContext, x: CGFloat, top: CGFloat, centered: Bool, scale: CGFloat) {
    let title = attributed("tegi", rounded(140 * scale, .bold), ink)
    let tagline = attributed("Scrollable tiling for macOS", rounded(38 * scale, .semibold), soft)
    let code = attributed(command, NSFont.monospacedSystemFont(ofSize: 24 * scale, weight: .semibold), blue)
    func left(_ w: CGFloat) -> CGFloat { centered ? x - w / 2 : x }

    var y = top - title.size().height
    title.draw(at: CGPoint(x: left(title.size().width) - (centered ? 0 : 6 * scale), y: y))
    y -= tagline.size().height + 2 * scale
    tagline.draw(at: CGPoint(x: left(tagline.size().width), y: y))

    let pad = CGSize(width: 22 * scale, height: 13 * scale)
    let pill = CGRect(x: left(code.size().width + 2 * pad.width), y: y - 34 * scale - code.size().height - 2 * pad.height,
                      width: code.size().width + 2 * pad.width, height: code.size().height + 2 * pad.height)
    let shape = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
    cg.addPath(shape)
    cg.setFillColor(CGColor(srgbRed: 0.06, green: 0.08, blue: 0.2, alpha: 0.55))
    cg.fillPath()
    cg.addPath(shape)
    cg.setStrokeColor(blue.withAlphaComponent(0.5).cgColor)
    cg.setLineWidth(1.5 * scale)
    cg.strokePath()
    code.draw(at: CGPoint(x: pill.minX + pad.width, y: pill.minY + pad.height))
}

// The landscape art is 3:2 with the characters on the left; cropping its middle band gives GitHub's 2:1.
render("og.png", width: 1280, height: 640) { cg in
    let art = NSImage(contentsOfFile: brand + "og-art.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let band = art.cropping(to: CGRect(x: 0, y: art.height / 8, width: art.width, height: art.height * 3 / 4))!
    cg.draw(band, in: CGRect(x: 0, y: 0, width: 1280, height: 640))
    // GitHub crops up to 40 pt from each edge.
    block(cg, x: 700, top: 500, centered: false, scale: 1)
}

render("social.png", width: 1200, height: 1200) { cg in
    let art = NSImage(contentsOfFile: brand + "social-art.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    cg.draw(art, in: CGRect(x: 0, y: 0, width: 1200, height: 1200))
    block(cg, x: 600, top: 420, centered: true, scale: 1.15)
}
