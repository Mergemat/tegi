// Draws Resources/brand/social-preview.png, the 1280×640 image GitHub shows when the repository is shared.
// Run from the repository root: swift scripts/social.swift
import AppKit

let width = 1280, height = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext

let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [CGColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1),
                                   CGColor(srgbRed: 0.08, green: 0.085, blue: 0.1, alpha: 1)] as CFArray,
                          locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

// GitHub crops up to 40 pt from each edge, so everything sits inside that border.
let logo = NSImage(contentsOfFile: "Resources/brand/logo.png")!
logo.draw(in: CGRect(x: 163, y: 140, width: 360, height: 360))

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}
func text(_ s: String, _ font: NSFont, _ color: NSColor, at point: CGPoint) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
}

let left: CGFloat = 587
text("tegi", rounded(132, .bold), NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1), at: CGPoint(x: left - 6, y: 334))
text("Scrollable tiling for macOS", rounded(40, .medium), NSColor(srgbRed: 0.62, green: 0.65, blue: 0.72, alpha: 1),
         at: CGPoint(x: left, y: 282))

let command = "brew install mergemat/tap/tegi"
let mono = NSFont.monospacedSystemFont(ofSize: 26, weight: .medium)
let size = NSAttributedString(string: command, attributes: [.font: mono]).size()
let pill = CGRect(x: left, y: 178, width: size.width + 48, height: size.height + 28)
cg.addPath(CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil))
cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
cg.fillPath()
cg.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 14, cornerHeight: 14, transform: nil))
cg.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 0.45))
cg.setLineWidth(1.5)
cg.strokePath()
text(command, mono, NSColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 1), at: CGPoint(x: pill.minX + 24, y: pill.minY + 14))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/brand/social-preview.png"))
print("Wrote Resources/brand/social-preview.png")
