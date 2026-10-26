import IOSurface
import QuartzCore
import CoreVideo
import Testing
@testable import tegi

@Test func aSurfaceWithoutBGRABytesCannotBeClassifiedAsAnInvisibleWindow() throws {
    let surface = try #require(IOSurface(properties: [.width: 128, .height: 128, .bytesPerElement: 1, .pixelFormat: 0x4c303038]))
    #expect(surface.lock(options: [], seed: nil) == 0)
    memset(surface.baseAddress, 0, surface.allocationSize)
    surface.unlock(options: [], seed: nil)
    let measured = Snapshots.measure(surface)
    #expect(measured.radius == nil)
    #expect(!measured.blank)
}

@Test func aReadableTransparentBGRASurfaceIsAnInvisibleWindow() throws {
    let surface = try #require(IOSurface(properties: [.width: 128, .height: 128, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA]))
    #expect(surface.lock(options: [], seed: nil) == 0)
    memset(surface.baseAddress, 0, surface.allocationSize)
    surface.unlock(options: [], seed: nil)
    #expect(Snapshots.measure(surface).blank)
}

@Test func aWindowDrawnOnTheGPUHasItsCornersReadFromAPictureOfIt() throws {
    // What a capture of such a window gives back: an image, at twice the points, with macOS's continuous corners.
    let layer = CALayer()
    layer.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    layer.backgroundColor = CGColor(gray: 0.2, alpha: 1)
    layer.cornerRadius = 58
    layer.cornerCurve = .continuous
    let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 3200,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    layer.render(in: context)
    let measured = Snapshots.measure(try #require(context.makeImage()))
    #expect(abs((measured.radius ?? 0) - 58) <= 1)
    #expect(!measured.blank)
}
