import Carbon.HIToolbox
import Foundation

/// Raccourci global par `RegisterEventHotKey` (Carbon). Contrairement à un `CGEventTap`,
/// aucune autorisation TCC n'est nécessaire, et la touche est avalée : l'app au premier
/// plan ne la reçoit pas.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x43_50_45_55   // 'CPEU'

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `nil` si la combinaison est déjà prise par une autre app ou par le système.
    init?(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hkID = EventHotKeyID(signature: Self.signature, id: id)
        let st = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
        guard st == noErr, ref != nil else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard st == noErr, hk.signature == HotKey.signature, let h = HotKey.handlers[hk.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async(execute: h)
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
