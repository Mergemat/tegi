import AppKit
import ScreenCaptureKit
import TegiCore

final class Snapshots {
    private(set) var images: [WindowID: IOSurface] = [:]
    private var inFlight: Set<WindowID> = []

    // The check takes over 10 ms, too slow for a keypress.
    private(set) var allowed = CGPreflightScreenCaptureAccess()

    func requestAccess() {
        DispatchQueue.global(qos: .utility).async {
            let ok = CGPreflightScreenCaptureAccess()
            DispatchQueue.main.async {
                self.allowed = ok
                if !ok { CGRequestScreenCaptureAccess() }
            }
        }
    }

    func forget(_ id: WindowID) { images[id] = nil }

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

    private static func displaySpace() -> (space: CGColorSpace, name: CFString) {
        let space = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if let name = space.name { return (space, name) }
        return (CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace.sRGB)
    }

    // The desktop is several windows below the normal layer: wallpaper, icons and widgets.
    func captureWallpapers(_ done: @escaping ([CGDirectDisplayID: IOSurface]) -> Void) {
        guard allowed else { return }
        let space = Self.displaySpace()
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            var out: [CGDirectDisplayID: IOSurface] = [:]
            for display in content.displays {
                let desktop = content.windows.filter { $0.windowLayer < 0 && $0.frame.intersects(display.frame) }
                guard !desktop.isEmpty else { continue }
                let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = Int(display.frame.width * scale)
                config.height = Int(display.frame.height * scale)
                config.showsCursor = false
                if let surface = await Self.surface(SCContentFilter(display: display, including: desktop), config, space) {
                    out[display.displayID] = surface
                }
            }
            let images = out
            await MainActor.run { done(images) }
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
            await withTaskGroup(of: (WindowID, IOSurface?).self) { group in
                for w in wanted {
                    guard let window = byID[w.windowID] else {
                        group.addTask { (w.id, nil) }
                        continue
                    }
                    group.addTask {
                        let config = SCStreamConfiguration()
                        config.width = Int(window.frame.width * scale)
                        config.height = Int(window.frame.height * scale)
                        config.showsCursor = false
                        config.ignoreShadowsSingleWindow = true
                        return (w.id, await Self.surface(SCContentFilter(desktopIndependentWindow: window), config, space))
                    }
                }
                for await (id, image) in group {
                    await MainActor.run {
                        self.inFlight.remove(id)
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
