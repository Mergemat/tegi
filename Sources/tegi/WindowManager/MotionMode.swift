import AppKit
import TegiCore

/// How windows get where the layout puts them. The window manager decides where everything goes; the mode the config
/// picks moves windows there and says where they show. Neither stands in for the other.
protocol MotionMode: AnyObject {
    /// The screen shows a window where tegi puts it as soon as tegi commits it, not once its app gets there.
    var presents: Bool { get }
    /// Slides and the overview show live windows rather than snapshots.
    var liveScenes: Bool { get }
    /// Why windows can't move this way right now, for Settings.
    var problem: String? { get }

    /// The way in, when the config picks this mode.
    func start()
    /// The way out: windows go back to native geometry and nothing of this mode's stays on screen.
    func stop()
    /// The world or the set of windows changed.
    func sync()

    /// The layout as this mode can show it.
    func layout(_ placements: [WindowID: Placement]) -> [WindowID: Placement]
    /// Where a window's next flight starts, when the screen shows it somewhere other than the spring has it.
    func start(_ id: WindowID, at now: CFTimeInterval) -> CGRect?
    func flying(_ id: WindowID, from: CGRect, to: CGRect)
    /// Where a window that doesn't fly goes.
    func rest(_ id: WindowID, _ p: Placement) -> CGRect
    func step(_ id: WindowID, _ frame: CGRect, monitor: Int, last: Bool)
    func send(_ id: WindowID, _ frame: CGRect, verify: Bool)
    /// Where a hidden floating window waits.
    func hide(_ win: Win, size: CGSize, on monitor: Int) -> CGRect
    /// Accessibility heard where tegi last sent a window.
    func landed(_ id: WindowID)
    /// Hands windows back to native geometry, at `restored` where given.
    func finish(restoring restored: [WindowID: CGRect])
    func release(_ id: WindowID)

    /// Where the window shows, if it does.
    func shown(_ id: WindowID, at now: CFTimeInterval) -> CGRect?
    /// Where tegi itself presents the window, apart from its app.
    func presented(_ id: WindowID) -> CGRect?
    /// The window's app redrew it.
    func refresh(_ id: WindowID)
    /// The size the app actually gave its window.
    func size(of win: Win) -> CGSize?
    /// Puts a window that sized itself back to its layout size.
    func force(_ id: WindowID, _ frame: CGRect)
    /// An Accessibility echo of a move or resize is worth reading.
    func heard(_ id: WindowID) -> Bool
    /// A reported resize is tegi's own, still landing.
    func echoes(_ id: WindowID) -> Bool
    /// The mouse is down on this window.
    func pressed(_ id: WindowID) -> Bool
    func smoothness(_ summary: String) -> String
}

extension WindowManager {
    func grabbed(_ id: WindowID) -> CGRect? {
        guard let g = grab, g.window == id, !g.resize, !g.floating else { return nil }
        return g.current
    }

    /// Where a flight or the layout has a window, if that's on screen.
    func laidOut(_ id: WindowID, at now: CFTimeInterval) -> CGRect? {
        let p = motion.current(id, at: now).map { world.place($0.frame.roundedToPoints, on: $0.monitor) } ?? targets[id]
        guard p?.visible == true else { return nil }
        return p?.frame
    }

    /// Native geometry, told to apps and waited for: what any mode leaves behind.
    func handBack(_ frames: [WindowID: CGRect]) {
        for (id, frame) in frames { sendAccessibility(id, frame, verify: true, force: true) }
        let group = DispatchGroup()
        for worker in workers.values { worker.flush(group) }
        _ = group.wait(timeout: .now() + 2)
    }
}
