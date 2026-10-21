import AppKit
import SwiftUI

/// Vérification visuelle sans autorisation d'enregistrement d'écran :
/// `Copeau --snapshot <dossier>` rend les vues (données de démonstration, base en mémoire,
/// aucune écriture) en clair et en sombre dans des fenêtres hors écran, puis quitte.
@MainActor
enum Snapshot {
    static func runIfRequested(model: PanelModel, settings: Settings, store: Store, monitor: ClipboardMonitor, state: AppState) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            model.prepareForShow()
            model.accessibilityGranted = true
            for (ap, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                render(PanelView(model: model).frame(width: 1480, height: 330), ap, dir, "panel-\(name)")
            }
            model.commandHeld = true
            model.moveSelection(2)
            render(PanelView(model: model).frame(width: 1480, height: 330), .darkAqua, dir, "panel-cmd")
            model.commandHeld = false

            model.selectedID = store.items.first { $0.kind == .link }?.id
            render(PreviewView(model: model).frame(width: 760, height: 480), .aqua, dir, "preview-link")
            model.selectedID = store.items.first { $0.meta.isCode }?.id
            render(PreviewView(model: model).frame(width: 760, height: 480), .darkAqua, dir, "preview-code")
            model.selectedID = store.items.first { $0.kind == .color }?.id
            render(PreviewView(model: model).frame(width: 760, height: 480), .aqua, dir, "preview-color")

            if let p = store.pinboards.first { model.tab = .pinboard(p.id) }
            render(PanelView(model: model).frame(width: 1480, height: 330), .aqua, dir, "panel-pinboard")
            model.tab = .history

            model.query = "zzzz introuvable"
            render(PanelView(model: model).frame(width: 1100, height: 300), .aqua, dir, "panel-empty")
            model.query = "pasteboard"
            render(PanelView(model: model).frame(width: 1100, height: 330), .darkAqua, dir, "panel-search")
            model.query = ""

            model.accessibilityGranted = false
            model.open(.newPinboard(pinItemID: nil))
            model.dialogText = "Réponses mail"
            render(PanelView(model: model).frame(width: 1100, height: 330), .aqua, dir, "panel-dialog")
            model.cancelDialog()

            for page in SettingsPage.Page.allCases {
                render(SettingsView(settings: settings, store: store, monitor: monitor, app: state, initialPage: page), .aqua, dir,
                       "settings-\(page.rawValue.folding(options: .diacriticInsensitive, locale: nil).lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
            render(ToastView(text: "Copié dans le presse-papiers", symbol: "checkmark.circle.fill"), .darkAqua, dir, "toast")
            exit(0)
        }
        return true
    }

    private static func render<V: View>(_ view: V, _ appearance: NSAppearance.Name, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

/// Données fictives pour `--demo` et `--snapshot` (jamais l'historique réel).
@MainActor
enum DemoData {
    static func fill(_ store: Store) {
        let now = Date()
        func add(_ snap: PasteboardSnapshot, _ app: String, _ name: String, minutesAgo: Double, title: String? = nil, pin: String? = nil) -> ClipItem? {
            guard var r = Classifier.classify(snap, appBundleID: app, appName: name, now: now.addingTimeInterval(-minutesAgo * 60)) else { return nil }
            r.item.title = title
            r.item.pinboardID = pin
            return store.add(r, snapshot: snap)
        }
        let links = store.createPinboard(name: "Liens utiles", colorIndex: 5)
        let snippets = store.createPinboard(name: "Snippets", colorIndex: 1)
        _ = store.createPinboard(name: "Alternance", colorIndex: 3)

        _ = add(.text("Bonjour Mme Martin,\n\nVous trouverez ci-joint le rapport d'avancement du sprint 14. Les tests de non-régression sont passés sur la pipeline Azure DevOps, il reste la revue de la PR sur le module de facturation.\n\nBien cordialement,\nPolat"),
                "com.apple.mail", "Mail", minutesAgo: 3 * 24 * 60, title: "Signature rapport sprint", pin: snippets.id)
        _ = add(.text("ssh polat@192.168.95.120 -t 'cd /opt/ansible && ansible-playbook site.yml --check'"),
                "com.apple.Terminal", "Terminal", minutesAgo: 2 * 24 * 60, pin: snippets.id)
        _ = add(.text("https://dev.azure.com/Isagri-Prod-Progiciels/Isagri_Dev_CO_Compta/_build"), "com.apple.Safari", "Safari",
                minutesAgo: 26 * 60, pin: links.id)
        let img = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.png.rawValue: demoImage()]])
        _ = add(img, "com.apple.Preview", "Aperçu", minutesAgo: 5 * 60)
        _ = add(PasteboardSnapshot(items: ["/System/Applications/Calculator.app", "/System/Applications/Notes.app", "/System/Applications/Utilities/Terminal.app"]
                    .map { [NSPasteboard.PasteboardType.fileURL.rawValue: URL(fileURLWithPath: $0).dataRepresentation] }),
                "com.apple.finder", "Finder", minutesAgo: 3 * 60)
        _ = add(.text("#FF6B35"), "com.apple.Safari", "Safari", minutesAgo: 95)
        _ = add(PasteboardSnapshot(items: [["com.apple.iWork.Keynote.KNSlide": Data(repeating: 7, count: 48_000)]]), "com.apple.iWork.Keynote", "Keynote", minutesAgo: 70)
        _ = add(.text("""
        func paste(_ item: ClipItem) {
            pasteboard.clearContents()
            pasteboard.writeObjects(items)
            postCommandV()
        }
        """), "com.apple.dt.Xcode", "Xcode", minutesAgo: 40)
        _ = add(.text("La rétro-ingénierie sert à comprendre un mécanisme, pas à copier du code : on observe, on documente, puis on réécrit de zéro."),
                "com.apple.Notes", "Notes", minutesAgo: 12)
        if let l = add(.text("https://developer.apple.com/documentation/appkit/nspasteboard"), "com.apple.Safari", "Safari", minutesAgo: 2, pin: links.id) {
            store.updateMeta(l.id, linkTitle: "NSPasteboard | Apple Developer Documentation", linkImage: nil)
        }
        _ = add(.text("rgb(52, 199, 89)"), "com.apple.TextEdit", "TextEdit", minutesAgo: 0.1)
    }

    private static func demoImage() -> Data {
        let size = NSSize(width: 1600, height: 1000)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.35, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.85, green: 0.25, blue: 0.6, alpha: 1)])!
                .draw(in: r, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            for (x, y, s) in [(300.0, 620.0, 260.0), (900.0, 300.0, 380.0), (1250.0, 700.0, 180.0)] {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s, height: s)).fill()
            }
            return true
        }
        let tiff = img.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
}
