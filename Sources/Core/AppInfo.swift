import AppKit
import LinkPresentation

/// Icône et couleur d'en-tête de carte pour une app source (la couleur dominante de son
/// icône), mises en cache par identifiant.
@MainActor
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: NSColor] = [:]

    static func icon(_ bundleID: String?) -> NSImage {
        let key = bundleID ?? "?"
        if let i = icons[key] { return i }
        let img: NSImage
        if bundleID == "com.apple.universal-clipboard" {
            img = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) ?? NSImage()
        } else if let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            img = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            img = NSWorkspace.shared.icon(for: .application)
        }
        icons[key] = img
        return img
    }

    static func color(_ bundleID: String?) -> NSColor {
        let key = bundleID ?? "?"
        if let c = colors[key] { return c }
        let c = bundleID == nil || bundleID == "com.apple.universal-clipboard"
            ? NSColor(srgbRed: 0.42, green: 0.45, blue: 0.52, alpha: 1)
            : dominantColor(icon(bundleID))
        colors[key] = c
        return c
    }

    /// Moyenne des pixels pondérée par saturation × opacité, puis ramenée à une teinte lisible sous du texte blanc.
    private static func dominantColor(_ image: NSImage) -> NSColor {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return .gray }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
        var gr = 0.0, gg = 0.0, gb = 0.0, gsum = 0.0
        for y in 0..<side {
            for x in 0..<side {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let s = c.saturationComponent, v = c.brightnessComponent
                gr += c.redComponent; gg += c.greenComponent; gb += c.blueComponent; gsum += 1
                let w = s * s * v
                guard w > 0.05 else { continue }
                r += c.redComponent * w; g += c.greenComponent * w; b += c.blueComponent * w; wsum += w
            }
        }
        let base: NSColor
        if wsum > 2 {
            base = NSColor(srgbRed: r / wsum, green: g / wsum, blue: b / wsum, alpha: 1)
        } else if gsum > 0 {
            base = NSColor(srgbRed: gr / gsum, green: gg / gsum, blue: gb / gsum, alpha: 1)
        } else {
            return .gray
        }
        let hue = base.hueComponent, sat = base.saturationComponent
        return NSColor(hue: hue, saturation: sat < 0.12 ? sat : min(max(sat, 0.45), 0.85),
                       brightness: min(max(base.brightnessComponent, 0.45), 0.72), alpha: 1)
    }
}

/// Aperçus de liens (titre + image) par LinkPresentation. Désactivé par défaut : cela
/// envoie une requête réseau vers chaque lien copié.
@MainActor
final class LinkPreviewer {
    private let store: Store
    private var inFlight: Set<String> = []

    init(store: Store) { self.store = store }

    func fetch(_ item: ClipItem) {
        guard item.kind == .link, !item.meta.linkFetched, !inFlight.contains(item.id),
              let url = item.linkURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        inFlight.insert(item.id)
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let id = item.id
        provider.startFetchingMetadata(for: url) { meta, _ in   // le prévisualiseur vit autant que l'app
            let title = meta?.title
            guard let imageProvider = meta?.imageProvider ?? meta?.iconProvider else {
                Task { @MainActor in self.finish(id, title: title, image: nil) }
                return
            }
            _ = imageProvider.loadDataRepresentation(for: .image) { data, _ in
                let png = data.flatMap { Classifier.imageThumbnail($0, maxPixel: 600)?.png }
                Task { @MainActor in self.finish(id, title: title, image: png) }
            }
        }
    }

    private func finish(_ id: String, title: String?, image: Data?) {
        inFlight.remove(id)
        store.updateMeta(id, linkTitle: title, linkImage: image)
    }
}
