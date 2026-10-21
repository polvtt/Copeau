import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Panneau sans bordure qui peut devenir fenêtre clé sans activer Copeau : l'app au
/// premier plan le reste, c'est elle qui recevra le ⌘V simulé.
final class KeyPanel: NSPanel {
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar                      // au-dessus du Dock (niveau 20)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
    }
}

enum Glass {
    /// Fond Liquid Glass (macOS 26+), repli sur un matériau flou.
    static func host(_ view: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.contentView = view
            return g
        }
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: v.leadingAnchor), view.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            view.topAnchor.constraint(equalTo: v.topAnchor), view.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }
}

/// Ouvre, ferme et anime le panneau ; route le clavier ; déclenche le collage.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let colleur: Colleur
    private let settings: Settings
    private let panel: KeyPanel
    private let preview: KeyPanel
    private let toast: KeyPanel
    private var monitors: [Any] = []
    private var target: NSRunningApplication?
    private var bag: Set<AnyCancellable> = []
    private var toastTimer: Timer?
    private(set) var isVisible = false

    static let margin: CGFloat = 10
    static let corner: CGFloat = 26

    var onOpenSettings: (() -> Void)?

    init(model: PanelModel, colleur: Colleur, settings: Settings) {
        self.model = model
        self.colleur = colleur
        self.settings = settings
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1200, height: settings.panelHeight))
        preview = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520))
        toast = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40))
        super.init()

        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = []
        panel.contentView = Glass.host(host, cornerRadius: Self.corner)
        panel.delegate = self
        panel.setAccessibilityLabel("Copeau")

        preview.acceptsKey = false
        preview.contentView = Glass.host(NSHostingView(rootView: PreviewView(model: model)), cornerRadius: 22)
        toast.acceptsKey = false
        toast.ignoresMouseEvents = true

        model.onPaste = { [weak self] item, plain in self?.paste(item, plainText: plain) }
        model.onCopy = { [weak self] item in self?.copy(item) }
        model.onClose = { [weak self] in self?.hide() }
        model.onOpenSettings = { [weak self] in self?.hide(); self?.onOpenSettings?() }
        model.onResize = { [weak self] h in self?.resize(to: h) }

        model.$previewOpen.removeDuplicates().sink { [weak self] open in
            DispatchQueue.main.async { open ? self?.showPreview() : self?.hidePreview() }
        }.store(in: &bag)
        settings.$hideDuringScreenSharing.sink { [weak self] hide in
            for w in [self?.panel, self?.preview].compactMap({ $0 }) { w.sharingType = hide ? .none : .readOnly }
        }.store(in: &bag)
    }

    // MARK: - Ouverture / fermeture

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard !isVisible else { return }
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? target : front
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let final = frame(on: screen, height: settings.panelHeight)
        var start = final
        start.origin.y = screen.frame.minY - final.height
        model.prepareForShow()
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        isVisible = true
        installMonitors()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        model.previewOpen = false
        hidePreview()
        guard animated else { panel.orderOut(nil); return }
        var end = panel.frame
        end.origin.y = (panel.screen?.frame.minY ?? 0) - end.height * 0.35
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(end, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func frame(on screen: NSScreen, height: Double) -> NSRect {
        let f = screen.frame
        let h = min(CGFloat(height), screen.visibleFrame.height * 0.8)
        return NSRect(x: f.minX + Self.margin, y: f.minY + Self.margin, width: f.width - 2 * Self.margin, height: h)
    }

    private func resize(to height: Double) {
        let h = min(max(height, 230), 640)
        settings.panelHeight = h
        guard let screen = panel.screen else { return }
        panel.setFrame(frame(on: screen, height: h), display: true)
        if model.previewOpen { showPreview() }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clic ailleurs, changement d'app ou de Space : on referme.
        if isVisible { hide() }
    }

    // MARK: - Collage

    private func paste(_ item: ClipItem, plainText: Bool) {
        hide(animated: false)
        let pasted = colleur.paste(item, plainText: plainText, into: target)
        if !pasted {
            showToast(settings.directPaste ? "Copié. ⌘V pour coller (Accessibilité requise pour coller seul)" : "Copié dans le presse-papiers",
                      symbol: "doc.on.clipboard")
        }
    }

    private func copy(_ item: ClipItem) {
        guard colleur.write(item, plainText: false) else { NSSound.beep(); return }
        model.store.markUsed(item.id)
        hide()
        showToast("Copié dans le presse-papiers", symbol: "checkmark.circle.fill")
    }

    // MARK: - Aperçu

    private func showPreview() {
        guard isVisible, model.selected != nil else { return }
        let base = panel.frame
        let screen = panel.screen?.visibleFrame ?? base
        let w = min(820, base.width - 40)
        let h = min(560, screen.maxY - base.maxY - 24)
        guard h > 180 else { return }
        preview.setFrame(NSRect(x: base.midX - w / 2, y: base.maxY + 12, width: w, height: h), display: true)
        preview.sharingType = panel.sharingType
        preview.alphaValue = 0
        preview.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            preview.animator().alphaValue = 1
        }
    }

    private func hidePreview() { preview.orderOut(nil) }

    // MARK: - Bulle

    func showToast(_ text: String, symbol: String) {
        let host = NSHostingView(rootView: ToastView(text: text, symbol: symbol))
        let size = host.fittingSize
        toast.contentView = Glass.host(host, cornerRadius: size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        toast.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 40, width: size.width, height: size.height), display: true)
        toast.alphaValue = 1
        toast.orderFrontRegardless()
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.toast.animator().alphaValue = 0 },
                                                    completionHandler: { MainActor.assumeIsolated { self.toast.orderOut(nil) } })
            }
        }
    }

    // MARK: - Clavier et molette

    private static let digitKeys: [UInt16] = [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3), UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5),
                                              UInt16(kVK_ANSI_6), UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9)]

    private func installMonitors() {
        removeMonitors()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.keyDown(e) ?? false }
            return used ? nil : e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated {
                let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                self?.model.commandHeld = f.contains(.command)
                self?.model.shiftHeld = f.contains(.shift)
            }
            return e
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.scroll(e) ?? false }
            return used ? nil : e
        } as Any)
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func keyDown(_ e: NSEvent) -> Bool {
        guard e.window === panel || e.window == nil else { return false }
        if model.dialog != nil { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let fieldEditor = panel.firstResponder as? NSTextView
        let hasSelection = (fieldEditor?.selectedRange().length ?? 0) > 0

        if flags.contains(.command) {
            if let n = Self.digitKeys.firstIndex(of: e.keyCode) {
                model.quickPaste(n, plainText: flags.contains(.shift))
                return true
            }
            switch Int(e.keyCode) {
            case kVK_Delete, kVK_ForwardDelete: model.deleteSelected(); return true
            case kVK_ANSI_C where !hasSelection: model.copySelected(); return true
            case kVK_LeftArrow: model.selectFirst(); return true
            case kVK_RightArrow: model.selectLast(); return true
            default: break
            }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case ",": model.onOpenSettings?(); return true
            case "w": hide(); return true
            case "f": model.focusToken += 1; return true
            case "n": model.open(.newText); return true
            case "e": if let it = model.selected, it.kind == .text, !it.text.isEmpty { model.open(.editText(it.id)) }; return true
            case "r": if let it = model.selected { model.open(.renameItem(it.id)) }; return true
            case "o": if let url = model.selected?.linkURL { NSWorkspace.shared.open(url); hide() }; return true
            default: return false
            }
        }
        if e.keyCode == UInt16(kVK_Space), flags.isEmpty, model.query.isEmpty || model.previewOpen {
            model.togglePreview()
            return true
        }
        // Clic sur une carte : le champ a pu perdre le focus. On le lui rend pour que la frappe filtre.
        if fieldEditor == nil {
            switch Int(e.keyCode) {
            case kVK_LeftArrow: model.moveSelection(-1); return true
            case kVK_RightArrow: model.moveSelection(1); return true
            case kVK_Return, kVK_ANSI_KeypadEnter: model.paste(plainText: flags.contains(.shift) ? !settings.plainTextByDefault : nil); return true
            case kVK_Escape: model.clearSearchOrClose(); return true
            default: focusSearchField()
            }
        }
        return false
    }

    private func focusSearchField() {
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable { return f }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        if let root = panel.contentView, let f = find(root) { panel.makeFirstResponder(f) }
    }

    /// Molette de souris (non précise) : défile carte par carte. Le trackpad garde son défilement natif.
    private func scroll(_ e: NSEvent) -> Bool {
        guard e.window === panel, !e.hasPreciseScrollingDeltas, model.dialog == nil else { return false }
        let d = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : -e.scrollingDeltaX
        guard d != 0 else { return false }
        model.moveSelection(d < 0 ? 1 : -1)
        return true
    }
}
