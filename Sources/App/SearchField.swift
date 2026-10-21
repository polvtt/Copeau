import AppKit
import SwiftUI

/// Champ de recherche AppKit : il garde le focus clavier pendant que le panneau est ouvert,
/// et ses commandes d'édition (flèches, ↩, ⎋, ⇥) pilotent les cartes. Taper filtre directement,
/// accents et touches mortes compris.
struct SearchField: NSViewRepresentable {
    @ObservedObject var model: PanelModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 15)
        f.placeholderString = "Rechercher"
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Rechercher dans l'historique")
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.model = model
        if f.stringValue != model.query { f.stringValue = model.query }
        if context.coordinator.focusToken != model.focusToken {
            context.coordinator.focusToken = model.focusToken
            DispatchQueue.main.async {
                guard let w = f.window else { return }
                w.makeFirstResponder(f)
                f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.utf16.count, length: 0)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var model: PanelModel
        var focusToken = -1

        init(model: PanelModel) { self.model = model }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            model.query = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            switch sel {
            case #selector(NSResponder.moveLeft(_:)): model.moveSelection(-1)
            case #selector(NSResponder.moveRight(_:)): model.moveSelection(1)
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)),
                 #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
                model.selectFirst()
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
                 #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)):
                model.selectLast()
            case #selector(NSResponder.insertNewline(_:)):
                model.paste(plainText: shift ? !model.settings.plainTextByDefault : nil)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):   // ⌥↩
                model.paste(plainText: !model.settings.plainTextByDefault)
            case #selector(NSResponder.cancelOperation(_:)): model.clearSearchOrClose()
            case #selector(NSResponder.insertTab(_:)): model.cycleTab(1)
            case #selector(NSResponder.insertBacktab(_:)): model.cycleTab(-1)
            case #selector(NSResponder.moveLeftAndModifySelection(_:)): model.moveSelection(-5)
            case #selector(NSResponder.moveRightAndModifySelection(_:)): model.moveSelection(5)
            default: return false
            }
            return true
        }
    }
}

/// Champ de saisie des dialogues (renommer, nouveau pinboard) : prend le focus à l'apparition,
/// ↩ valide, ⎋ annule.
struct DialogField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.font = .systemFont(ofSize: 14)
        f.placeholderString = placeholder
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        DispatchQueue.main.async { f.window?.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DialogField
        init(_ p: DialogField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// Éditeur multiligne (modifier le texte d'un élément) ; ⌘↩ valide, ⎋ annule.
struct DialogTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.delegate = context.coordinator
        tv.string = text
        scroll.borderType = .bezelBorder
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DialogTextView
        init(_ p: DialogTextView) { parent = p }

        func textDidChange(_ n: Notification) {
            if let tv = n.object as? NSTextView { parent.text = tv.string }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onCancel(); return true }
            if sel == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                parent.onSubmit(); return true
            }
            return false
        }
    }
}
