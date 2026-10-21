import AppKit
import ApplicationServices

/// Remet un élément sur le presse-papiers et, si l'Accessibilité est accordée, simule ⌘V
/// dans l'app qui avait le premier plan (le panneau ne l'active jamais à sa place).
@MainActor
final class Colleur {
    private let store: Store
    private let monitor: ClipboardMonitor
    private let settings: Settings
    private let pasteboard = NSPasteboard.general

    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    init(store: Store, monitor: ClipboardMonitor, settings: Settings) {
        self.store = store
        self.monitor = monitor
        self.settings = settings
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Demande l'Accessibilité (ouvre l'invite système la première fois).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Écrit l'élément sur le presse-papiers. Retourne faux si ses données ont disparu.
    @discardableResult
    func write(_ item: ClipItem, plainText: Bool) -> Bool {
        pasteboard.clearContents()
        defer { monitor.ignore(changeCount: pasteboard.changeCount) }
        if plainText || item.kind == .color {
            let s = item.kind == .color ? (item.meta.colorHex ?? item.text) : item.text
            guard !s.isEmpty else { return writeSnapshot(item) }
            pasteboard.setString(s, forType: .string)
            pasteboard.setString(Bundle.main.bundleIdentifier ?? "", forType: Self.sourceType)
            return true
        }
        return writeSnapshot(item)
    }

    private func writeSnapshot(_ item: ClipItem) -> Bool {
        guard let snap = store.snapshot(for: item.id) else {
            if !item.text.isEmpty { pasteboard.setString(item.text, forType: .string); return true }
            return false
        }
        let objects: [NSPasteboardItem] = snap.items.enumerated().map { i, dict in
            let pb = NSPasteboardItem()
            for (type, data) in dict { pb.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            if i == 0 { pb.setString(Bundle.main.bundleIdentifier ?? "", forType: Self.sourceType) }
            return pb
        }
        return pasteboard.writeObjects(objects)
    }

    /// Copie puis colle dans `target`. Retourne vrai si ⌘V a été simulé.
    @discardableResult
    func paste(_ item: ClipItem, plainText: Bool, into target: NSRunningApplication?) -> Bool {
        guard write(item, plainText: plainText) else { NSSound.beep(); return false }
        store.markUsed(item.id)
        guard settings.directPaste, Self.isTrusted else { return false }
        let delay: TimeInterval
        if let target, !target.isActive {
            target.activate()
            delay = 0.18
        } else {
            delay = 0.05
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.postCommandV()
            if self.settings.soundEffects { NSSound(named: "Pop")?.play() }
        }
        return true
    }

    /// ⌘V synthétique. Le code de touche dépend de la disposition (AZERTY, Dvorak…).
    static func postCommandV() {
        let v = KeyboardLayout.keyCode(for: "v") ?? 9
        let src = CGEventSource(stateID: .combinedSessionState)
        // Ignorer les modificateurs physiquement enfoncés (⇧ du raccourci) pendant le collage.
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                        state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
