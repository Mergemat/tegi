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

    /// Captures can be GPU-only or use a different pixel layout despite the requested format.
    static func readable(_ surface: IOSurface) -> Bool {
        surface.pixelFormat == kCVPixelFormatType_32BGRA && surface.width > 0 && surface.height > 0
            && surface.width <= surface.bytesPerRow / 4 && surface.bytesPerRow <= surface.allocationSize / surface.height
            && Int(bitPattern: surface.baseAddress) != 0
    }

    static func measure(_ image: CGImage) -> (radius: Double?, blank: Bool) {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (nil, false) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return (nil, false) }
        let base = data.assumingMemoryBound(to: UInt8.self)
        let alpha = { (x: Int, y: Int) in base[(y * w + x) * 4 + 3] }
        return (Corners.radius(width: w, height: h, alpha: alpha), Corners.isBlank(width: w, height: h, alpha: alpha))
    }

    static func measure(_ surface: IOSurface) -> (radius: Double?, blank: Bool) {
        guard surface.lock(options: .readOnly, seed: nil) == KERN_SUCCESS else { return (nil, false) }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        // An unreadable surface says nothing about whether the source window is invisible.
        guard readable(surface) else { return (nil, false) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self), row = surface.bytesPerRow
        let alpha = { (x: Int, y: Int) in base[y * row + x * 4 + 3] }
        return (Corners.radius(width: surface.width, height: surface.height, alpha: alpha),
                Corners.isBlank(width: surface.width, height: surface.height, alpha: alpha))
    }

    /// A window's size in points as the window server has it right now.
    private static func size(_ id: CGWindowID) -> CGSize? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return rect.size
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

    /// `tries` counts the pictures of a window taken while it was resizing; a few more follow until it holds still.
    func refresh(_ windows: [(id: WindowID, windowID: CGWindowID)], scale: CGFloat, tries: Int = 0, updated: @escaping (WindowID) -> Void) {
        let wanted = windows.filter { $0.windowID != 0 && !inFlight.contains($0.id) }
        guard allowed, !wanted.isEmpty else { return }
        inFlight.formUnion(wanted.map(\.id))
        let space = Self.displaySpace()
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let byID = Dictionary((content?.windows ?? []).map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: ((id: WindowID, windowID: CGWindowID), IOSurface?, Double?, Bool, Bool).self) { group in
                for w in wanted {
                    guard let window = byID[w.windowID] else {
                        group.addTask { (w, nil, nil, false, false) }
                        continue
                    }
                    group.addTask {
                        // A window bigger than the size asked for comes back shrunk to fit, corners and all, so a
                        // just-opened window that tegi resizes after the list above was taken would measure small.
                        // Its size is asked for again right before the picture, and checked again after it.
                        let size = Self.size(window.windowID) ?? window.frame.size
                        let config = SCStreamConfiguration()
                        config.width = Int(size.width * scale)
                        config.height = Int(size.height * scale)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        let surface = await Self.surface(filter, config, space)
                        var measured = surface.map(Self.measure)
                        // Windows the app draws on the GPU come back GPU-only, with no pixels to read; a picture of
                        // one has them.
                        if let surface, !Self.readable(surface),
                           let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            measured = Self.measure(image)
                        }
                        // Resized while it was taken, the picture may be shrunk: no radius from it.
                        let unchanged = Self.size(window.windowID).map { abs($0.width - size.width) < 1 && abs($0.height - size.height) < 1 } ?? true
                        return (w, surface, unchanged ? measured?.radius.map { $0 / scale } : nil, measured?.blank ?? false, !unchanged)
                    }
                }
                for await (w, image, radius, blank, resizing) in group {
                    let id = w.id
                    await MainActor.run {
                        self.inFlight.remove(id)
                        if let radius { self.radii[id] = radius }
                        // A window just opened is often still being sized; its corners are measured once it holds still.
                        if resizing, tries < 4 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh([w], scale: scale, tries: tries + 1, updated: updated) }
                        }
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
