// Draws Resources/AppIcon.icns: a strip of columns running off both edges, the middle one focused.
// Run from the repository root: swift scripts/icon.swift
import AppKit

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let u = s / 1024

    // Apple's icon grid: an 824 pt rounded square centered in 1024.
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: CGColor(gray: 0, alpha: 0.35))
    cg.addPath(shape)
    cg.setFillColor(CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.17, green: 0.18, blue: 0.22, alpha: 1),
                                       CGColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let top = tile.maxY - 170 * u, bottom = tile.minY + 170 * u, gap = 44 * u, width = 236 * u
    let middle = tile.midX - width / 2
    for (i, x) in [middle - width - gap, middle, middle + width + gap].enumerated() {
        let column = CGRect(x: x, y: bottom, width: width, height: top - bottom)
        let path = CGPath(roundedRect: column, cornerWidth: 36 * u, cornerHeight: 36 * u, transform: nil)
        cg.addPath(path)
        cg.setFillColor(i == 1 ? CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
                               : CGColor(srgbRed: 0.42, green: 0.44, blue: 0.5, alpha: 1))
        cg.fillPath()
        if i == 1 {
            let ring = CGPath(roundedRect: column.insetBy(dx: -20 * u, dy: -20 * u), cornerWidth: 54 * u, cornerHeight: 54 * u, transform: nil)
            cg.addPath(ring)
            cg.setStrokeColor(CGColor(srgbRed: 0.5, green: 0.78, blue: 1, alpha: 1))
            cg.setLineWidth(14 * u)
            cg.strokePath()
        }
    }
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! draw(points).write(to: set.appending(path: "icon_\(points)x\(points).png"))
    try! draw(points * 2).write(to: set.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try! FileManager.default.createDirectory(at: URL(fileURLWithPath: "Resources"), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
