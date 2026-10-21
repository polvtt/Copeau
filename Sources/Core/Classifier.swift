import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Transforme un instantané du presse-papiers en élément d'historique : nature, texte,
/// métadonnées d'affichage, empreinte pour les doublons et vignette éventuelle.
enum Classifier {
    struct Result {
        var item: ClipItem
        var thumbnail: Data?
    }

    static let codeApps: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.zed.Zed", "com.jetbrains.intellij", "com.panic.Nova",
        "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.exafunction.windsurf",
    ]

    static func classify(_ snap: PasteboardSnapshot, appBundleID: String?, appName: String?,
                         isRemote: Bool = false, now: Date = Date()) -> Result? {
        var meta = ClipMeta()
        meta.byteSize = snap.byteSize
        meta.isRemote = isRemote
        let types = snap.allTypes
        var kind = ClipKind.text
        var text = ""
        var checksum: String
        var thumbnail: Data?

        let files = snap.fileURLs
        let string = snap.string
        if !files.isEmpty {
            kind = .files
            meta.filePaths = files.map(\.path)
            text = files.map(\.lastPathComponent).joined(separator: "\n")
            checksum = Checksum.of(Data(meta.filePaths.joined(separator: "\n").utf8))
            if files.count == 1, let t = fileThumbnail(files[0]) {
                thumbnail = t.png; meta.hasThumbnail = true
                meta.imageWidth = t.width; meta.imageHeight = t.height
            }
        } else if let s = string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = s
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            checksum = Checksum.of(Data(s.utf8))
            meta.charCount = s.count
            meta.lineCount = s.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            if isLink(trimmed) {
                kind = .link
            } else if let hex = colorHex(trimmed) {
                kind = .color
                meta.colorHex = hex
            } else {
                meta.isRich = types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
                    || types.contains(NSPasteboard.PasteboardType.html.rawValue)
                    || types.contains("com.apple.flat-rtfd")
                meta.isCode = looksLikeCode(s, app: appBundleID)
            }
        } else if let img = snap.imageData {
            kind = .image
            checksum = Checksum.of(img)
            if let t = imageThumbnail(img) {
                thumbnail = t.png; meta.hasThumbnail = true
                meta.imageWidth = t.width; meta.imageHeight = t.height
            }
        } else if snap.byteSize > 0 {
            // Types privés uniquement (Figma, Sketch, Keynote…) : on garde l'élément pour le recoller fidèlement.
            kind = .text
            text = ""
            var all = Data()
            for item in snap.items { for k in item.keys.sorted() { all.append(Data(k.utf8)); all.append(item[k]!) } }
            checksum = Checksum.of(all)
        } else {
            return nil
        }

        let item = ClipItem(id: UUID().uuidString, kind: kind, created: now, lastUsed: now, title: nil, text: text,
                            appBundleID: appBundleID, appName: appName, pinboardID: nil, checksum: checksum, meta: meta)
        return Result(item: item, thumbnail: thumbnail)
    }

    // MARK: - Détection

    static func isLink(_ s: String) -> Bool {
        guard s.count < 4_000, !s.contains(where: { $0.isWhitespace }), let u = URL(string: s), let scheme = u.scheme?.lowercased()
        else { return false }
        switch scheme {
        case "http", "https", "ftp", "sftp", "ssh": return u.host?.isEmpty == false
        case "mailto", "tel", "facetime", "maps", "x-apple.systempreferences": return true
        default: return false
        }
    }

    private static let hexRegex = try! NSRegularExpression(pattern: "^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
    private static let funcRegex = try! NSRegularExpression(
        pattern: "^(rgba?|hsla?)\\(\\s*([0-9.]+%?)\\s*[, ]\\s*([0-9.]+%?)\\s*[, ]\\s*([0-9.]+%?)\\s*(?:[,/]\\s*([0-9.]+%?)\\s*)?\\)$",
        options: [.caseInsensitive])

    /// « #RGB », « #RRGGBB(AA) », « rgb(…) », « hsl(…) » → hexadécimal canonique « #RRGGBB ».
    static func colorHex(_ s: String) -> String? {
        let r = NSRange(s.startIndex..., in: s)
        if hexRegex.firstMatch(in: s, range: r) != nil {
            var h = String(s.dropFirst()).uppercased()
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            return "#" + h.prefix(6)
        }
        guard let m = funcRegex.firstMatch(in: s, range: r) else { return nil }
        func g(_ i: Int) -> String { (s as NSString).substring(with: m.range(at: i)) }
        func num(_ v: String, scale: Double) -> Double {
            v.hasSuffix("%") ? (Double(v.dropLast()) ?? 0) / 100 * scale : (Double(v) ?? 0)
        }
        let fn = g(1).lowercased()
        var red = 0.0, green = 0.0, blue = 0.0
        if fn.hasPrefix("rgb") {
            red = num(g(2), scale: 255) / 255; green = num(g(3), scale: 255) / 255; blue = num(g(4), scale: 255) / 255
        } else {
            let h = (Double(g(2)) ?? 0) / 360, sat = num(g(3), scale: 1), l = num(g(4), scale: 1)
            (red, green, blue) = hslToRGB(h, sat > 1 ? sat / 100 : sat, l > 1 ? l / 100 : l)
        }
        guard [red, green, blue].allSatisfy({ (0...1).contains($0) }) else { return nil }
        return String(format: "#%02X%02X%02X", Int(red * 255 + 0.5), Int(green * 255 + 0.5), Int(blue * 255 + 0.5))
    }

    private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0; if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }

    static func looksLikeCode(_ s: String, app: String?) -> Bool {
        if let app, codeApps.contains(app) { return true }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).prefix(200)
        guard lines.count >= 2 else {
            return s.hasPrefix("$ ") || s.hasPrefix("sudo ") || s.contains(" && ") || s.contains(" | grep")
        }
        var score = 0
        for l in lines {
            if l.hasPrefix("    ") || l.hasPrefix("\t") { score += 1 }
            if l.hasSuffix(";") || l.hasSuffix("{") || l.hasSuffix("}") || l.hasSuffix(":") && l.hasPrefix(" ") { score += 1 }
            if l.contains("=>") || l.contains("->") || l.contains("func ") || l.contains("def ") || l.contains("const ") { score += 1 }
        }
        return Double(score) / Double(lines.count) > 0.5
    }

    // MARK: - Vignettes

    struct Thumb { var png: Data; var width: Int; var height: Int }

    static func imageThumbnail(_ data: Data, maxPixel: Int = 640) -> Thumb? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(src, maxPixel: maxPixel)
    }

    static func fileThumbnail(_ url: URL) -> Thumb? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 80_000_000,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(src, maxPixel: 640)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> Thumb? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        var w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let o = props?[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if w == 0 { w = cg.width; h = cg.height }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return Thumb(png: out as Data, width: w, height: h)
    }
}
