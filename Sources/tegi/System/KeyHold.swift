import AppKit
import TegiCore

/// Holds typing while focus is on its way to another app and replays it there once that app is in front, so a key
/// pressed right after moving never lands in the window just left. tegi's own shortcuts always go through.
final class KeyHold {
    private var tap: CFMachPort?
    private let lock = NSLock()
    private var holding = false
    private var held: [CGEvent] = []
    private var binds: Set<Int> = []
    private static let replayed: Int64 = 0x7465_6769
    /// Typing is the sign the moving is over, so the first held key asks for the app at once.
    var onTyping: () -> Void = {}

    init?() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, me in
                                              Unmanaged<KeyHold>.fromOpaque(me!).takeUnretainedValue().handle(type, event)
                                          }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        // Its own thread, so a busy main thread never delays typing.
        Thread.detachNewThread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
    }

    func passing(_ binds: some Sequence<KeyCombo>) {
        lock.lock()
        self.binds = Set(binds.map { Self.code(Int($0.keyCode), $0.mods) })
        lock.unlock()
    }

    private var holds = 0

    /// Lets go by itself after a second, so a hung app can't swallow typing.
    func hold() {
        lock.lock()
        holding = true
        holds += 1
        let mine = holds
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            lock.lock()
            let stale = holding && holds == mine
            lock.unlock()
            if stale { release() }
        }
    }

    func release() {
        lock.lock()
        holding = false
        let events = held
        held = []
        lock.unlock()
        for e in events {
            e.setIntegerValueField(.eventSourceUserData, value: Self.replayed)
            e.post(tap: .cgSessionEventTap)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.replayed else { return Unmanaged.passUnretained(event) }
        lock.lock()
        defer { lock.unlock() }
        guard holding, !binds.contains(combo(event)), let copy = event.copy() else { return Unmanaged.passUnretained(event) }
        held.append(copy)
        if held.count == 1 { DispatchQueue.main.async(execute: onTyping) }
        return nil
    }

    private static func code(_ key: Int, _ mods: Mods) -> Int { key << 8 | mods.rawValue }

    private func combo(_ event: CGEvent) -> Int {
        var mods: Mods = []
        if event.flags.contains(.maskCommand) { mods.insert(.cmd) }
        if event.flags.contains(.maskAlternate) { mods.insert(.alt) }
        if event.flags.contains(.maskControl) { mods.insert(.ctrl) }
        if event.flags.contains(.maskShift) { mods.insert(.shift) }
        return Self.code(Int(event.getIntegerValueField(.keyboardEventKeycode)), mods)
    }
}
