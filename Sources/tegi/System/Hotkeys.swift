import Carbon.HIToolbox
import TegiCore

final class Hotkeys {
    private var registered: [KeyCombo: (ref: EventHotKeyRef, id: UInt32)] = [:]
    private var commands: [UInt32: Command] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private let run: (Command) -> Void

    init(run: @escaping (Command) -> Void) {
        self.run = run
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, me in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(me!).takeUnretainedValue()
            if let command = hotkeys.commands[id.id] { hotkeys.run(command) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ binds: [KeyCombo: Command]) -> [KeyCombo] {
        for (combo, reg) in registered where binds[combo] == nil {
            UnregisterEventHotKey(reg.ref)
            commands[reg.id] = nil
            registered[combo] = nil
        }
        var refused: [KeyCombo] = []
        for (combo, command) in binds {
            if let reg = registered[combo] {
                commands[reg.id] = command
                continue
            }
            var mods: UInt32 = 0
            if combo.mods.contains(.cmd) { mods |= UInt32(cmdKey) }
            if combo.mods.contains(.alt) { mods |= UInt32(optionKey) }
            if combo.mods.contains(.ctrl) { mods |= UInt32(controlKey) }
            if combo.mods.contains(.shift) { mods |= UInt32(shiftKey) }
            var ref: EventHotKeyRef?
            let id = nextID
            nextID += 1
            if RegisterEventHotKey(combo.keyCode, mods, EventHotKeyID(signature: OSType(0x7465_6769), id: id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                registered[combo] = (ref, id)
                commands[id] = command
            } else {
                refused.append(combo)
            }
        }
        return refused
    }

    func unregisterAll() { _ = register([:]) }
}
