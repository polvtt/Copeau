import AppKit
import Combine
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Agent de barre des menus : relie stockage, capture, panneau, raccourci et réglages.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var settings: Settings!
    private var monitor: ClipboardMonitor!
    private var colleur: Colleur!
    private var model: PanelModel!
    private var panel: PanelController!
    private var links: LinkPreviewer!
    private let state = AppState()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var bag: Set<AnyCancellable> = []
    private var purgeTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        let demo = args.contains("--demo") || args.contains("--snapshot")
        settings = Settings()
        if demo {
            store = Store.inMemory()
            DemoData.fill(store)
        } else {
            do { store = try Store.persistent() } catch {
                let a = NSAlert(); a.messageText = "Impossible d'ouvrir l'historique"; a.informativeText = "\(error)"; a.runModal()
                NSApp.terminate(nil); return
            }
        }
        monitor = ClipboardMonitor(store: store, settings: settings)
        colleur = Colleur(store: store, monitor: monitor, settings: settings)
        model = PanelModel(store: store, settings: settings, monitor: monitor)
        links = LinkPreviewer(store: store)

        if Snapshot.runIfRequested(model: model, settings: settings, store: store, monitor: monitor, state: state) { return }

        panel = PanelController(model: model, colleur: colleur, settings: settings)
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        monitor.onCapture = { [weak self] item in
            guard let self, self.settings.linkPreviews else { return }
            self.links.fetch(item)
        }
        setupStatusItem()

        settings.$shortcut.removeDuplicates().sink { [weak self] s in self?.registerHotKey(s) }.store(in: &bag)
        state.$recordingShortcut.removeDuplicates().sink { [weak self] rec in
            guard let self else { return }
            rec ? (self.hotKey = nil) : self.registerHotKey(self.settings.shortcut)
        }.store(in: &bag)
        settings.$retention.sink { [weak self] _ in DispatchQueue.main.async { self?.purge() } }.store(in: &bag)
        monitor.$isPaused.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusIcon() } }.store(in: &bag)

        purgeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purge() }
        }
        if !demo { monitor.start() }

        // Premier lancement : expliquer, puis ouvrir les réglages sur les autorisations.
        if !UserDefaults.standard.bool(forKey: "onboarded") && !demo {
            UserDefaults.standard.set(true, forKey: "onboarded")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.welcome() }
        }
        if args.contains("--open") || demo { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.panel.show() } }
        log.notice("Copeau démarré (\(self.store.items.count) éléments, raccourci \(self.settings.shortcut.display, privacy: .public), presse-papiers \(String(describing: self.monitor.access), privacy: .public), accessibilité \(Colleur.isTrusted))")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()     // relancer l'app (Finder, Spotlight) ouvre le panneau
        return false
    }

    private func registerHotKey(_ s: Shortcut) {
        hotKey = nil
        hotKey = HotKey(s) { [weak self] in
            MainActor.assumeIsolated { self?.panel.toggle() }
        }
        state.hotKeyFailed = hotKey == nil
        if hotKey == nil { log.error("raccourci \(s.display, privacy: .public) indisponible") }
        rebuildMenu()
    }

    private func purge() {
        if let limit = settings.retention.limitDate { store.purge(olderThan: limit) }
    }

    // MARK: - Barre des menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.setAccessibilityLabel("Copeau")
        updateStatusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let name = monitor.isPaused ? "pause.circle" : "doc.on.clipboard"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Copeau")
        img?.isTemplate = true
        button.image = img
        button.toolTip = monitor.isPaused ? "Copeau — capture en pause" : "Copeau"
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let open = NSMenuItem(title: "Ouvrir Copeau (\(settings.shortcut.display))", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let recent = store.items.prefix(9)
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Récents"))
            for (i, it) in recent.enumerated() {
                let title = (it.displayTitle ?? (it.text.isEmpty ? Fmt.kindTitle(it) : it.text))
                    .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let mi = NSMenuItem(title: String(title.prefix(48)) + (title.count > 48 ? "…" : ""), action: #selector(copyRecent(_:)),
                                    keyEquivalent: i < 9 ? "\(i + 1)" : "")
                mi.target = self
                mi.representedObject = it.id
                let icon = AppInfo.icon(it.appBundleID).copy() as! NSImage
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        let pause = NSMenuItem(title: monitor.isPaused ? "Reprendre la capture" : "Mettre la capture en pause",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let skip = NSMenuItem(title: "Ignorer la prochaine copie", action: #selector(skipNext), keyEquivalent: "")
        skip.target = self
        menu.addItem(skip)
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Vider l'historique…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        let prefs = NSMenuItem(title: "Réglages…", action: #selector(openSettingsAction), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Copeau", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openPanel() { panel.show() }
    @objc private func togglePause() { monitor.isPaused.toggle() }
    @objc private func skipNext() { monitor.ignoreNextCopy() }
    @objc private func openSettingsAction() { openSettings() }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let it = store.item(id) else { return }
        // Le menu a gardé l'app active au premier plan : on y colle directement.
        colleur.paste(it, plainText: settings.plainTextByDefault, into: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Vider l'historique ?"
        a.informativeText = "Les \(store.items.filter { $0.pinboardID == nil }.count) éléments non épinglés seront supprimés. Les pinboards restent intacts."
        a.addButton(withTitle: "Vider")
        a.addButton(withTitle: "Annuler")
        a.buttons[0].hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }

    // MARK: - Réglages

    func openSettings(page: SettingsPage.Page? = nil) {
        state.refresh()
        monitor.refreshAccess()
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings, store: store, monitor: monitor, app: state, initialPage: page))
            let w = NSWindow(contentViewController: host)
            w.title = "Réglages de Copeau"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func welcome() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Copeau est prêt"
        a.informativeText = """
        Appuie sur \(settings.shortcut.display) pour ouvrir l'historique du presse-papiers.

        Deux autorisations macOS :
        • Presse-papiers : à la première copie, macOS demande si Copeau peut lire le presse-papiers. Choisis « Toujours autoriser ».
        • Accessibilité : pour que Copeau colle à ta place (⌘V simulé). Sans elle, il copie seulement.
        """
        a.addButton(withTitle: "Autoriser l'Accessibilité…")
        a.addButton(withTitle: "Plus tard")
        if a.runModal() == .alertFirstButtonReturn { Colleur.requestTrust() }
    }
}
