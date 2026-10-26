import AppKit
import ScreenCaptureKit
import TegiCore

final class Snapshots {
    private(set) var images: [WindowID: IOSurface] = [:]
    /// Each window's corner radius in points, measured from its picture.
    private(set) var radii: [WindowID: Double] = [:]
    /// Windows whose picture shows nothing: invisible helpers some apps keep, which nothing should offer to switch to.
    private(set) var blank: Set<WindowID> = []
    private var inFlight: Set<WindowID> = []

    // The check takes over 10 ms, too slow for a keypress.
    private(set) var allowed = CGPreflightScreenCaptureAccess()

    func refreshAccess(prompt: Bool) {
        DispatchQueue.global(qos: .utility).async {
            let ok = CGPreflightScreenCaptureAccess()
            DispatchQueue.main.async {
                self.allowed = ok
                if !ok && prompt { CGRequestScreenCaptureAccess() }
            }
        }
    }

    func forget(_ id: WindowID) {
        images[id] = nil
        radii[id] = nil
        blank.remove(id)
    }

    // A CGImage is uploaded to the GPU on first display, stalling that frame; a surface isn't.
    private static func surface(_ filter: SCContentFilter, _ config: SCStreamConfiguration,
                                _ space: (space: CGColorSpace, name: CFString)) async -> IOSurface? {
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = space.name
        let buffer = try? await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
        guard let surface = buffer?.imageBuffer.flatMap({ CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }) else { return nil }
        // Core Animation reads the color space from the surface, not the buffer.
        if let list = space.space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list) }
        return surface
    }

    private static func surface(_ image: CGImage, _ space: CGColorSpace) -> IOSurface? {
        let w = image.width, h = image.height
        guard let surface = IOSurface(properties: [.width: w, .height: h, .bytesPerElement: 4,
                                                   .pixelFormat: kCVPixelFormatType_32BGRA]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: surface.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: space, bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let list = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, list) }
        return surface
    }

    static func measure(_ surface: IOSurface) -> (radius: Double?, blank: Bool) {
        guard surface.lock(options: .readOnly, seed: nil) == KERN_SUCCESS else { return (nil, false) }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        // Captures can be GPU-only or use a different pixel layout despite the requested format.
        // An unreadable surface says nothing about whether the source window is invisible.
        guard surface.pixelFormat == kCVPixelFormatType_32BGRA,
              surface.width > 0, surface.height > 0,
              surface.width <= surface.bytesPerRow / 4,
              surface.bytesPerRow <= surface.allocationSize / surface.height,
              Int(bitPattern: surface.baseAddress) != 0 else { return (nil, false) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self), row = surface.bytesPerRow
        let alpha = { (x: Int, y: Int) in base[y * row + x * 4 + 3] }
        return (Corners.radius(width: surface.width, height: surface.height, alpha: alpha),
                Corners.isBlank(width: surface.width, height: surface.height, alpha: alpha))
    }

    private static func displaySpace() -> (space: CGColorSpace, name: CFString) {
        let space = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if let name = space.name { return (space, name) }
        return (CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace.sRGB)
    }

    // The desktop is several windows below the normal layer: wallpaper, icons and widgets.
    /// Each display's desktop as it looks, icons and widgets too, and its bare wallpaper alone.
    func captureWallpapers(_ done: @escaping (_ desktops: [CGDirectDisplayID: IOSurface], _ papers: [CGDirectDisplayID: IOSurface]) -> Void) {
        guard allowed else { return }
        let space = Self.displaySpace()
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            var out: [CGDirectDisplayID: IOSurface] = [:], papers: [CGDirectDisplayID: IOSurface] = [:]
            for display in content.displays {
                let desktop = content.windows.filter { $0.windowLayer < 0 && $0.frame.intersects(display.frame) }
                guard !desktop.isEmpty else { continue }
                let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = Int(display.frame.width * scale)
                config.height = Int(display.frame.height * scale)
                config.showsCursor = false
                config.colorSpaceName = space.name
                // The sample-buffer capture leaves out Finder's desktop icons; the image capture keeps them.
                let filter = SCContentFilter(display: display, including: desktop)
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                   let surface = Self.surface(image, space.space) {
                    out[display.displayID] = surface
                }
                // macOS draws the wallpaper in a window of its own beneath the icons. A quarter of the pixels is plenty to blur.
                let paper = desktop.filter { $0.title == "Wallpaper" && $0.owningApplication?.bundleIdentifier == "com.apple.WindowManager" }
                if !paper.isEmpty {
                    config.width /= 4
                    config.height /= 4
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: paper), configuration: config),
                       let surface = Self.surface(image, space.space) {
                        papers[display.displayID] = surface
                    }
                }
            }
            let (desktops, bare) = (out, papers)
            await MainActor.run { done(desktops, bare) }
        }
    }

    func refresh(_ windows: [(id: WindowID, windowID: CGWindowID)], scale: CGFloat, updated: @escaping (WindowID) -> Void) {
        let wanted = windows.filter { $0.windowID != 0 && !inFlight.contains($0.id) }
        guard allowed, !wanted.isEmpty else { return }
        inFlight.formUnion(wanted.map(\.id))
        let space = Self.displaySpace()
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let byID = Dictionary((content?.windows ?? []).map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (WindowID, IOSurface?, Double?, Bool).self) { group in
                for w in wanted {
                    guard let window = byID[w.windowID] else {
                        group.addTask { (w.id, nil, nil, false) }
                        continue
                    }
                    group.addTask {
                        let config = SCStreamConfiguration()
                        config.width = Int(window.frame.width * scale)
                        config.height = Int(window.frame.height * scale)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let surface = await Self.surface(SCContentFilter(desktopIndependentWindow: window), config, space)
                        let measured = surface.map(Self.measure)
                        return (w.id, surface, measured?.radius.map { $0 / scale }, measured?.blank ?? false)
                    }
                }
                for await (id, image, radius, blank) in group {
                    await MainActor.run {
                        self.inFlight.remove(id)
                        if let radius { self.radii[id] = radius }
                        if image != nil { if blank { self.blank.insert(id) } else { self.blank.remove(id) } }
                        if let image {
                            self.images[id] = image
                            updated(id)
                        }
                    }
                }
            }
        }
    }
}
