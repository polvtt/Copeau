import AppKit

/// Surveille le presse-papiers général. macOS ne notifie pas ses changements : on scrute
/// `changeCount`, puis on attend un court instant que l'app source ait fini d'écrire tous
/// ses types avant de lire.
@MainActor
final class ClipboardMonitor: ObservableObject {
    enum Access: Equatable { case unknown, allowed, ask, denied }

    @Published var isPaused = false
    @Published private(set) var access: Access = .unknown
    @Published private(set) var captureCount = 0

    var onCapture: ((ClipItem) -> Void)?

    private let pasteboard = NSPasteboard.general
    private let store: Store
    private let settings: Settings
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCounts: Set<Int> = []
    private var skipNext = false
    private var pending: Timer?

    static let pollInterval: TimeInterval = 0.4
    static let settleDelay: TimeInterval = 0.15
    static let maxBytesPerType = 64 << 20       // 64 Mo
    static let maxBytesPerItem = 160 << 20

    init(store: Store, settings: Settings) {
        self.store = store
        self.settings = settings
        // Au lancement, on reprend le dernier jeton connu : une copie faite pendant que Copeau
        // était fermé est capturée, mais pas le contenu déjà enregistré.
        let saved = UserDefaults.standard.object(forKey: "lastChangeCount") as? Int
        lastChangeCount = saved ?? NSPasteboard.general.changeCount
        refreshAccess()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Ne pas capturer ce que Copeau écrit lui-même (collage d'un élément).
    func ignore(changeCount: Int) { ignoredChangeCounts.insert(changeCount) }

    /// « Ignorer la prochaine copie » (menu de la barre des menus).
    func ignoreNextCopy() { skipNext = true }

    func refreshAccess() {
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysAllow: access = .allowed
            case .alwaysDeny: access = .denied
            case .ask: access = .ask
            default: access = .unknown            // jamais demandé : la première lecture déclenchera l'alerte
            }
        } else {
            access = .allowed
        }
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        UserDefaults.standard.set(count, forKey: "lastChangeCount")

        if ignoredChangeCounts.remove(count) != nil { return }
        if skipNext { skipNext = false; return }
        if isPaused { return }

        // L'app source se lit maintenant, pas après le délai : l'utilisateur a pu changer d'app entre-temps.
        let front = NSWorkspace.shared.frontmostApplication
        let types = Set((pasteboard.types ?? []).map(\.rawValue))   // lire les types ne déclenche pas l'alerte de confidentialité
        // Minuterie en mode « common » et non DispatchQueue.main : la file principale n'est pas servie
        // pendant une boucle modale (NSAlert.runModal), et la copie serait perdue.
        pending?.invalidate()
        let t = Timer(timeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture(expected: count, front: front, types: types) }
        }
        RunLoop.main.add(t, forMode: .common)
        pending = t
    }

    private func capture(expected: Int, front: NSRunningApplication?, types: Set<String>) {
        guard pasteboard.changeCount == expected else { return }   // une autre copie est arrivée : le prochain tour la traitera
        if types.isEmpty { log.notice("changement \(expected) sans type lisible"); return }
        if let banned = types.first(where: { settings.allBannedTypes.contains($0) }) {
            log.notice("type ignoré \(banned, privacy: .public)")
            return
        }
        var bundleID = front?.bundleIdentifier
        var appName = front?.localizedName
        // Convention nspasteboard.org : l'app source peut se déclarer elle-même.
        if types.contains("org.nspasteboard.source"), let src = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")), !src.isEmpty {
            bundleID = src
            appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: src)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? appName
        }
        if bundleID == Bundle.main.bundleIdentifier { return }
        if let id = bundleID, settings.ignoredApps.contains(id) {
            log.notice("app ignorée \(id, privacy: .public)")
            return
        }
        let isRemote = types.contains("com.apple.is-remote-clipboard")
        if isRemote { bundleID = "com.apple.universal-clipboard"; appName = "Presse-papiers universel" }

        guard let snap = read() else {
            refreshAccess()
            log.notice("changement \(expected) : lecture impossible (accès \(String(describing: self.access), privacy: .public))")
            return
        }
        refreshAccess()
        guard let result = Classifier.classify(snap, appBundleID: bundleID, appName: appName, isRemote: isRemote),
              let item = store.add(result, snapshot: snap) else { log.notice("changement \(expected) : rien d'exploitable"); return }
        captureCount += 1
        log.notice("capture \(item.kind.label, privacy: .public) depuis \(bundleID ?? "?", privacy: .public) (\(snap.byteSize) o)")
        if settings.soundEffects { NSSound(named: "Tink")?.play() }
        onCapture?(item)
    }

    /// Lit tous les types de tous les items. C'est cette lecture qui déclenche l'alerte de
    /// confidentialité de macOS 15.4+ tant que Copeau n'est pas en « Toujours autoriser ».
    private func read() -> PasteboardSnapshot? {
        guard let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else { return nil }
        var out: [[String: Data]] = []
        var total = 0
        for pbItem in pbItems {
            var dict: [String: Data] = [:]
            for type in pbItem.types {
                // Les types dynamiques « dyn.* » sont des doublons opaques des types publics : on les garde
                // quand même, certaines apps (Office) ne relisent que les leurs.
                guard let data = pbItem.data(forType: type) else { continue }
                if data.count > Self.maxBytesPerType {
                    log.notice("type trop gros ignoré \(type.rawValue, privacy: .public) (\(data.count) o)")
                    continue
                }
                total += data.count
                if total > Self.maxBytesPerItem { return nil }
                dict[type.rawValue] = data
            }
            if !dict.isEmpty { out.append(dict) }
        }
        return out.isEmpty ? nil : PasteboardSnapshot(items: out)
    }
}
