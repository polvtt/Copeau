import AppKit
import CryptoKit
import SwiftUI

/// Nature d'un élément, déduite de ses types au moment de la capture.
enum ClipKind: Int, Codable, CaseIterable, Identifiable {
    case text = 0, link = 1, image = 2, files = 3, color = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .text: "Texte"
        case .link: "Lien"
        case .image: "Image"
        case .files: "Fichiers"
        case .color: "Couleur"
        }
    }

    var pluralLabel: String {
        switch self {
        case .text: "Textes"
        case .link: "Liens"
        case .image: "Images"
        case .files: "Fichiers"
        case .color: "Couleurs"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc"
        case .color: "paintpalette"
        }
    }
}

/// Métadonnées d'affichage, stockées en JSON avec l'élément.
struct ClipMeta: Codable, Equatable {
    var byteSize: Int = 0
    var charCount: Int = 0
    var lineCount: Int = 0
    var isRich = false              // RTF ou HTML disponible
    var isCode = false              // heuristique : police à chasse fixe
    var isRemote = false            // presse-papiers universel (iPhone, iPad)
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var hasThumbnail = false
    var filePaths: [String] = []
    var colorHex: String?
    var linkTitle: String?
    var hasLinkImage = false
    var linkFetched = false
}

/// Un élément de l'historique. Les données brutes vivent à part (`PasteboardSnapshot`),
/// chargées seulement pour coller, glisser ou afficher l'aperçu.
struct ClipItem: Identifiable, Equatable {
    let id: String
    var kind: ClipKind
    var created: Date               // première copie
    var lastUsed: Date              // dernière copie ou dernier collage : clé de tri
    var title: String?              // renommage par l'utilisateur
    var text: String                // texte brut (recherche, aperçu, collage en texte brut)
    var appBundleID: String?
    var appName: String?
    var pinboardID: String?
    var checksum: String
    var meta: ClipMeta

    var displayTitle: String? { (title?.isEmpty == false) ? title : nil }

    var linkURL: URL? { kind == .link ? URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }

    var fileURLs: [URL] { meta.filePaths.map { URL(fileURLWithPath: $0) } }

    /// Texte normalisé pour la recherche (sans casse ni accents).
    func matches(_ tokens: [String]) -> Bool {
        let hay = [text.prefix(20_000).description, title ?? "", appName ?? "", meta.linkTitle ?? "",
                   meta.filePaths.map { ($0 as NSString).lastPathComponent }.joined(separator: " ")]
            .joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return tokens.allSatisfy { hay.contains($0) }
    }
}

struct Pinboard: Identifiable, Equatable {
    let id: String
    var name: String
    var colorIndex: Int
    var order: Int

    var color: Color { Palette.color(colorIndex) }
}

enum Palette {
    static let colors: [Color] = [
        Color(red: 0.98, green: 0.30, blue: 0.30), Color(red: 1.00, green: 0.58, blue: 0.10),
        Color(red: 0.98, green: 0.80, blue: 0.10), Color(red: 0.25, green: 0.78, blue: 0.38),
        Color(red: 0.10, green: 0.70, blue: 0.85), Color(red: 0.25, green: 0.48, blue: 1.00),
        Color(red: 0.62, green: 0.38, blue: 0.95), Color(red: 0.95, green: 0.35, blue: 0.70),
        Color(red: 0.55, green: 0.55, blue: 0.60),
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

/// Contenu brut du presse-papiers : un dictionnaire type → données par `NSPasteboardItem`.
/// C'est ce qui permet de recoller fidèlement (RTF, HTML, images, fichiers, types privés).
struct PasteboardSnapshot: Codable {
    var items: [[String: Data]]

    var allTypes: Set<String> { Set(items.flatMap(\.keys)) }
    var byteSize: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    func first(_ type: NSPasteboard.PasteboardType) -> Data? {
        items.lazy.compactMap { $0[type.rawValue] }.first
    }

    var string: String? {
        if let d = first(.string), let s = String(data: d, encoding: .utf8) { return s }
        if let d = items.lazy.compactMap({ $0["public.utf16-plain-text"] }).first {
            return String(data: d, encoding: .utf16LittleEndian) ?? String(data: d, encoding: .utf16)
        }
        return nil
    }

    var fileURLs: [URL] {
        items.compactMap { $0[NSPasteboard.PasteboardType.fileURL.rawValue] }
            .compactMap { URL(dataRepresentation: $0, relativeTo: nil) }
            .filter(\.isFileURL)
    }

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("public.webp"),
    ]

    var imageData: Data? {
        for t in Self.imageTypes { if let d = first(t) { return d } }
        return nil
    }

    func encoded() throws -> Data {
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        return try enc.encode(self)
    }

    static func decode(_ data: Data) throws -> PasteboardSnapshot {
        try PropertyListDecoder().decode(PasteboardSnapshot.self, from: data)
    }

    /// Instantané d'une simple chaîne (élément créé à la main, démo).
    static func text(_ s: String) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(s.utf8)]])
    }
}

enum Checksum {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
