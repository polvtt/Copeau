import AppKit
import os

let log = Logger(subsystem: "com.polat.copeau", category: "core")

/// Historique et pinboards. Les métadonnées sont en SQLite et en mémoire ; les données
/// brutes (un plist binaire par élément) et les vignettes sont des fichiers à côté.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [ClipItem] = []         // tri : dernière utilisation, récente d'abord
    @Published private(set) var pinboards: [Pinboard] = []

    let directory: URL?                                         // nil : base en mémoire (démo)
    private let db: Database
    private var memoryBlobs: [String: Data] = [:]
    private let imageCache = NSCache<NSString, NSImage>()

    private init(directory: URL?, db: Database) {
        self.directory = directory
        self.db = db
        imageCache.countLimit = 300
        migrate()
        load()
    }

    static func persistent() throws -> Store {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Copeau", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        // Pas de sauvegarde Time Machine d'un historique de presse-papiers (mots de passe copiés…).
        var d = dir; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? d.setResourceValues(rv)
        let db = try Database(path: dir.appendingPathComponent("copeau.sqlite").path)
        return Store(directory: dir, db: db)
    }

    static func inMemory() -> Store { Store(directory: nil, db: Database()) }

    // MARK: - Schéma

    private func migrate() {
        do {
            if db.userVersion < 1 {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS items(
                  id TEXT PRIMARY KEY, kind INTEGER NOT NULL, created REAL NOT NULL, last_used REAL NOT NULL,
                  title TEXT, text TEXT NOT NULL, app_bundle TEXT, app_name TEXT, pinboard TEXT,
                  checksum TEXT NOT NULL, meta TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS items_last_used ON items(last_used DESC);
                CREATE INDEX IF NOT EXISTS items_checksum ON items(checksum);
                CREATE TABLE IF NOT EXISTS pinboards(id TEXT PRIMARY KEY, name TEXT NOT NULL, color INTEGER NOT NULL, ord INTEGER NOT NULL);
                """)
                db.userVersion = 1
            }
        } catch { log.error("migration : \(String(describing: error), privacy: .public)") }
    }

    private func load() {
        var list: [ClipItem] = []
        let dec = JSONDecoder()
        try? db.query("SELECT id, kind, created, last_used, title, text, app_bundle, app_name, pinboard, checksum, meta FROM items ORDER BY last_used DESC") { r in
            let meta = (r.text(10)?.data(using: .utf8)).flatMap { try? dec.decode(ClipMeta.self, from: $0) } ?? ClipMeta()
            list.append(ClipItem(id: r.text(0)!, kind: ClipKind(rawValue: r.int(1)) ?? .text,
                                 created: Date(timeIntervalSinceReferenceDate: r.real(2)),
                                 lastUsed: Date(timeIntervalSinceReferenceDate: r.real(3)),
                                 title: r.text(4), text: r.text(5) ?? "", appBundleID: r.text(6), appName: r.text(7),
                                 pinboardID: r.text(8), checksum: r.text(9) ?? "", meta: meta))
        }
        var boards: [Pinboard] = []
        try? db.query("SELECT id, name, color, ord FROM pinboards ORDER BY ord") { r in
            boards.append(Pinboard(id: r.text(0)!, name: r.text(1) ?? "", colorIndex: r.int(2), order: r.int(3)))
        }
        items = list
        pinboards = boards
    }

    // MARK: - Ajout

    /// Ajoute un élément capturé. Une copie identique (même empreinte) remonte l'élément existant.
    @discardableResult
    func add(_ result: Classifier.Result, snapshot: PasteboardSnapshot) -> ClipItem? {
        let new = result.item
        if let i = items.firstIndex(where: { $0.checksum == new.checksum && $0.kind == new.kind }) {
            var existing = items.remove(at: i)
            existing.lastUsed = new.lastUsed
            existing.appBundleID = new.appBundleID ?? existing.appBundleID
            existing.appName = new.appName ?? existing.appName
            items.insert(existing, at: 0)
            // Les types peuvent avoir changé (même texte, autre mise en forme) : on garde le plus récent.
            writeBlob(existing.id, "plist", try? snapshot.encoded())
            save(existing)
            return existing
        }
        guard let data = try? snapshot.encoded() else { return nil }
        writeBlob(new.id, "plist", data)
        if let t = result.thumbnail { writeBlob(new.id, "thumb.png", t) }
        items.insert(new, at: 0)
        save(new)
        return new
    }

    /// Élément créé à la main (texte saisi dans Copeau).
    @discardableResult
    func addText(_ text: String, pinboardID: String?) -> ClipItem? {
        let snap = PasteboardSnapshot.text(text)
        guard var r = Classifier.classify(snap, appBundleID: Bundle.main.bundleIdentifier, appName: "Copeau") else { return nil }
        r.item.pinboardID = pinboardID
        return add(r, snapshot: snap)
    }

    // MARK: - Lecture

    func snapshot(for id: String) -> PasteboardSnapshot? {
        guard let data = readBlob(id, "plist") else { return nil }
        return try? PasteboardSnapshot.decode(data)
    }

    func thumbnail(for item: ClipItem) -> NSImage? { image(item.id, "thumb.png", when: item.meta.hasThumbnail) }
    func linkImage(for item: ClipItem) -> NSImage? { image(item.id, "link.png", when: item.meta.hasLinkImage) }

    private func image(_ id: String, _ ext: String, when flag: Bool) -> NSImage? {
        guard flag else { return nil }
        let key = "\(id).\(ext)" as NSString
        if let img = imageCache.object(forKey: key) { return img }
        guard let data = readBlob(id, ext), let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    func item(_ id: String) -> ClipItem? { items.first { $0.id == id } }

    var totalBytes: Int { items.reduce(0) { $0 + $1.meta.byteSize } }

    // MARK: - Modification

    func markUsed(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: i)
        it.lastUsed = Date()
        items.insert(it, at: 0)
        save(it)
    }

    func rename(_ id: String, to title: String?) {
        update(id) { $0.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }

    func pin(_ id: String, to pinboardID: String?) { update(id) { $0.pinboardID = pinboardID } }

    func updateMeta(_ id: String, linkTitle: String?, linkImage: Data?) {
        if let linkImage { writeBlob(id, "link.png", linkImage) }
        update(id) {
            $0.meta.linkFetched = true
            if let linkTitle, !linkTitle.isEmpty { $0.meta.linkTitle = linkTitle }
            if linkImage != nil { $0.meta.hasLinkImage = true }
        }
    }

    func updateText(_ id: String, _ text: String) {
        guard let it = item(id) else { return }
        let snap = PasteboardSnapshot.text(text)
        guard let r = Classifier.classify(snap, appBundleID: it.appBundleID, appName: it.appName) else { return }
        writeBlob(id, "plist", try? snap.encoded())
        update(id) {
            $0.text = text; $0.kind = r.item.kind; $0.meta = r.item.meta; $0.checksum = r.item.checksum
        }
    }

    private func update(_ id: String, _ change: (inout ClipItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        save(items[i])
    }

    func delete(_ ids: [String]) {
        let set = Set(ids)
        items.removeAll { set.contains($0.id) }
        try? db.transaction {
            for id in ids { try db.run("DELETE FROM items WHERE id = ?", [.text(id)]) }
        }
        for id in ids { removeBlobs(id) }
    }

    /// Vide l'historique. Les éléments épinglés restent.
    func clearHistory() {
        delete(items.filter { $0.pinboardID == nil }.map(\.id))
    }

    /// Applique la durée de conservation (les éléments épinglés n'expirent jamais).
    func purge(olderThan limit: Date) {
        let old = items.filter { $0.pinboardID == nil && $0.lastUsed < limit }.map(\.id)
        if !old.isEmpty {
            log.notice("purge : \(old.count) élément(s) expiré(s)")
            delete(old)
        }
    }

    // MARK: - Pinboards

    @discardableResult
    func createPinboard(name: String, colorIndex: Int) -> Pinboard {
        let p = Pinboard(id: UUID().uuidString, name: name, colorIndex: colorIndex, order: (pinboards.map(\.order).max() ?? 0) + 1)
        pinboards.append(p)
        savePinboard(p)
        return p
    }

    func updatePinboard(_ id: String, name: String? = nil, colorIndex: Int? = nil) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        if let name { pinboards[i].name = name }
        if let colorIndex { pinboards[i].colorIndex = colorIndex }
        savePinboard(pinboards[i])
    }

    /// Supprime le pinboard ; ses éléments retournent dans l'historique.
    func deletePinboard(_ id: String) {
        pinboards.removeAll { $0.id == id }
        _ = try? db.run("DELETE FROM pinboards WHERE id = ?", [.text(id)])
        for it in items where it.pinboardID == id { pin(it.id, to: nil) }
    }

    func movePinboard(_ id: String, by delta: Int) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard pinboards.indices.contains(j) else { return }
        pinboards.swapAt(i, j)
        for k in pinboards.indices { pinboards[k].order = k; savePinboard(pinboards[k]) }
    }

    // MARK: - Persistance

    private func save(_ it: ClipItem) {
        let meta = (try? JSONEncoder().encode(it.meta)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            try db.run("""
            INSERT OR REPLACE INTO items(id, kind, created, last_used, title, text, app_bundle, app_name, pinboard, checksum, meta)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, [.text(it.id), .int(it.kind.rawValue), .real(it.created.timeIntervalSinceReferenceDate),
                  .real(it.lastUsed.timeIntervalSinceReferenceDate), .text(it.title), .text(it.text),
                  .text(it.appBundleID), .text(it.appName), .text(it.pinboardID), .text(it.checksum), .text(meta)])
        } catch { log.error("enregistrement : \(String(describing: error), privacy: .public)") }
    }

    private func savePinboard(_ p: Pinboard) {
        _ = try? db.run("INSERT OR REPLACE INTO pinboards(id, name, color, ord) VALUES(?,?,?,?)",
                    [.text(p.id), .text(p.name), .int(p.colorIndex), .int(p.order)])
    }

    private func blobURL(_ id: String, _ ext: String) -> URL? {
        directory?.appendingPathComponent("blobs").appendingPathComponent("\(id).\(ext)")
    }

    private func writeBlob(_ id: String, _ ext: String, _ data: Data?) {
        guard let data else { return }
        imageCache.removeObject(forKey: "\(id).\(ext)" as NSString)
        if let url = blobURL(id, ext) { try? data.write(to: url, options: .atomic) } else { memoryBlobs["\(id).\(ext)"] = data }
    }

    private func readBlob(_ id: String, _ ext: String) -> Data? {
        if let url = blobURL(id, ext) { return try? Data(contentsOf: url) }
        return memoryBlobs["\(id).\(ext)"]
    }

    private func removeBlobs(_ id: String) {
        for ext in ["plist", "thumb.png", "link.png"] {
            imageCache.removeObject(forKey: "\(id).\(ext)" as NSString)
            if let url = blobURL(id, ext) { try? FileManager.default.removeItem(at: url) } else { memoryBlobs["\(id).\(ext)"] = nil }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
