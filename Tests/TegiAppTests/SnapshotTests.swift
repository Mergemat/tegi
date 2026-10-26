import IOSurface
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
