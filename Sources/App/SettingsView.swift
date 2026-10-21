import AppKit
import ServiceManagement
import SwiftUI

/// État partagé entre l'app et la fenêtre de réglages.
@MainActor
final class AppState: ObservableObject {
    @Published var hotKeyFailed = false
    @Published var recordingShortcut = false
    @Published var accessibility = Colleur.isTrusted
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchError: String?

    func refresh() {
        accessibility = Colleur.isTrusted
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        refresh()
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

final class SettingsPage: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case general = "Général", shortcuts = "Raccourcis", privacy = "Confidentialité", storage = "Stockage", about = "À propos"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .privacy: "hand.raised"
            case .storage: "internaldrive"
            case .about: "info.circle"
            }
        }
    }
    @Published var page: Page = .general
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: Store
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var app: AppState
    @StateObject private var nav = SettingsPage()
    var initialPage: SettingsPage.Page? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsPage.Page.allCases) { p in
                    Button { nav.page = p } label: {
                        VStack(spacing: 3) {
                            Image(systemName: p.symbol).font(.system(size: 17))
                            Text(p.rawValue).font(.system(size: 11))
                        }
                        .frame(width: 92, height: 50)
                        .background(RoundedRectangle(cornerRadius: 8).fill(nav.page == p ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(nav.page == p ? Color.accentColor : Color.primary)
                }
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch nav.page {
                case .general: GeneralPane(settings: settings, monitor: monitor, app: app)
                case .shortcuts: ShortcutsPane(settings: settings, app: app)
                case .privacy: PrivacyPane(settings: settings)
                case .storage: StoragePane(settings: settings, store: store)
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 520)
        .onAppear { if let p = initialPage { nav.page = p } }
    }
}

// MARK: - Général

struct GeneralPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Ouvrir Copeau à l'ouverture de session", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                if let e = app.launchError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Coller") {
                Toggle("Coller directement dans l'app active", isOn: $settings.directPaste)
                if settings.directPaste {
                    PermissionRow(granted: app.accessibility, title: "Accessibilité",
                                  detail: app.accessibility ? "Copeau peut simuler ⌘V." : "Sans elle, l'élément est seulement copié.",
                                  action: { Colleur.requestTrust(); Links.openAccessibilityPrivacy() })
                }
                Toggle("Toujours coller en texte brut", isOn: $settings.plainTextByDefault)
                Text("⇧↩ ou ⇧⌘1…9 font l'inverse du réglage choisi.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Capture") {
                PermissionRow(granted: monitor.access == .allowed, title: "Accès au presse-papiers",
                              detail: accessDetail,
                              action: Links.openPasteboardPrivacy)
                Toggle("Mettre la capture en pause", isOn: $monitor.isPaused)
                Toggle("Sons à la copie et au collage", isOn: $settings.soundEffects)
                Toggle("Aperçus des liens", isOn: $settings.linkPreviews)
                Text("Télécharge le titre et l'image de chaque lien copié : une requête réseau part vers le site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refresh(); monitor.refreshAccess() }
    }

    private var accessDetail: String {
        switch monitor.access {
        case .allowed: "Toujours autorisé."
        case .ask: "macOS demande à chaque copie : choisis « Toujours autoriser »."
        case .denied: "Refusé : rien n'est capturé."
        case .unknown: "macOS posera la question à la première copie : réponds « Toujours autoriser »."
        }
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Ouvrir Réglages…", action: action) }
        }
    }
}

// MARK: - Raccourcis

struct ShortcutsPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var app: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Ouvrir Copeau")
                    Spacer()
                    ShortcutRecorder(settings: settings, app: app)
                }
                if app.hotKeyFailed {
                    Label("Ce raccourci est déjà pris par une autre app ou par macOS.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Dans le panneau") {
                ForEach(Self.help, id: \.0) { k, v in
                    HStack {
                        Text(v)
                        Spacer()
                        Text(k).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    static let help: [(String, String)] = [
        ("← →", "Carte précédente / suivante"),
        ("↩", "Coller"),
        ("⇧↩", "Coller en texte brut"),
        ("⌘1 … ⌘9", "Coller la n-ième carte"),
        ("Espace", "Aperçu"),
        ("⇥ / ⇧⇥", "Onglet suivant / précédent"),
        ("⌘C", "Copier sans coller"),
        ("⌘⌫", "Supprimer"),
        ("⌘R / ⌘E", "Renommer / modifier le texte"),
        ("⌘N", "Nouvel élément texte"),
        ("⎋", "Effacer la recherche, puis fermer"),
    ]
}

/// Bouton qui capte la prochaine combinaison de touches (au moins ⌘, ⌥ ou ⌃).
struct ShortcutRecorder: View {
    @ObservedObject var settings: Settings
    @ObservedObject var app: AppState
    @StateObject private var rec = Recorder()

    @MainActor
    final class Recorder: ObservableObject {
        var monitor: Any?
        func stop(_ app: AppState) {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
            app.recordingShortcut = false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                app.recordingShortcut ? rec.stop(app) : start()
            } label: {
                Text(app.recordingShortcut ? "Tape le raccourci…" : settings.shortcut.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 130)
            }
            if settings.shortcut != .default && !app.recordingShortcut {
                Button { settings.shortcut = .default } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Revenir à ⇧⌘V")
            }
        }
        .onDisappear { rec.stop(app) }
    }

    private func start() {
        app.recordingShortcut = true
        rec.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let code = e.keyCode
            let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
            MainActor.assumeIsolated {
                if code == 53 { rec.stop(app); return }          // ⎋ : annuler
                guard !f.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return }
                settings.shortcut = Shortcut(keyCode: UInt32(code), modifiers: f.rawValue)
                rec.stop(app)
            }
            return nil
        }
    }
}

// MARK: - Confidentialité

struct PrivacyPane: View {
    @ObservedObject var settings: Settings
    @StateObject private var sel = Selection()

    final class Selection: ObservableObject {
        @Published var app: String?
        @Published var newType = ""
    }

    var body: some View {
        Form {
            Section {
                Toggle("Masquer Copeau des partages et captures d'écran", isOn: $settings.hideDuringScreenSharing)
            }
            Section("Apps ignorées") {
                List(selection: $sel.app) {
                    ForEach(settings.ignoredApps, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(nsImage: AppInfo.icon(id)).resizable().frame(width: 18, height: 18)
                            Text(appName(id))
                            Spacer()
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                        }
                        .tag(id)
                    }
                }
                .frame(height: 150)
                HStack {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button { if let a = sel.app { settings.ignoredApps.removeAll { $0 == a }; sel.app = nil } } label: { Image(systemName: "minus") }
                        .disabled(sel.app == nil)
                    Spacer()
                    Button("Rétablir la liste par défaut") { settings.ignoredApps = Settings.defaultIgnoredApps }
                }
                .buttonStyle(.borderless)
            }
            Section("Types ignorés") {
                Text("Toujours ignorés : contenus marqués transitoires ou masqués (conventions nspasteboard.org, utilisées par les gestionnaires de mots de passe).")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.ignoredTypes, id: \.self) { t in
                    HStack {
                        Text(t).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { settings.ignoredTypes.removeAll { $0 == t } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Identifiant de type (ex. com.adobe.pdf)", text: $sel.newType)
                    Button("Ajouter") {
                        let t = sel.newType.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !settings.ignoredTypes.contains(t) { settings.ignoredTypes.append(t) }
                        sel.newType = ""
                    }
                    .disabled(sel.newType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Ignorer"
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.ignoredApps.contains(id) { settings.ignoredApps.append(id) }
        }
    }
}

// MARK: - Stockage

struct StoragePane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var store: Store
    @StateObject private var confirm = Confirm()

    final class Confirm: ObservableObject { @Published var clear = false }

    var body: some View {
        Form {
            Section("Historique") {
                Picker("Conserver l'historique", selection: $settings.retention) {
                    ForEach(Retention.allCases) { Text($0.label).tag($0) }
                }
                Text("Les éléments épinglés dans un pinboard sont conservés indéfiniment.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Contenu") {
                LabeledContent("Éléments", value: Fmt.count(store.items.count))
                LabeledContent("Épinglés", value: Fmt.count(store.items.filter { $0.pinboardID != nil }.count))
                LabeledContent("Pinboards", value: Fmt.count(store.pinboards.count))
                LabeledContent("Taille", value: Fmt.bytes(store.totalBytes))
                ForEach(ClipKind.allCases) { k in
                    let n = store.items.filter { $0.kind == k }.count
                    if n > 0 { LabeledContent(k.pluralLabel, value: Fmt.count(n)).foregroundStyle(.secondary) }
                }
            }
            Section {
                HStack {
                    Button("Vider l'historique…") { confirm.clear = true }
                    Spacer()
                    if let dir = store.directory {
                        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Vider l'historique ?", isPresented: $confirm.clear) {
            Button("Vider", role: .destructive) { store.clearHistory() }
        } message: {
            Text("Les éléments non épinglés seront supprimés. Les pinboards restent intacts.")
        }
    }
}

// MARK: - À propos

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Copeau").font(.system(size: 22, weight: .bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .foregroundStyle(.secondary)
            Text("Historique du presse-papiers et pinboards. Tout reste sur ce Mac : aucune synchronisation, aucune statistique d'usage.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 400)
        }
        .padding(.top, 50)
    }
}
