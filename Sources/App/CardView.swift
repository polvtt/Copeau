import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f
    }()

    static func ago(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 10 { return "à l'instant" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM yyyy 'à' HH:mm"
        return f
    }()

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "fr_FR")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(count(n)) \(n > 1 ? many : one)" }

    /// Ligne d'information en pied de carte.
    static func footer(_ it: ClipItem) -> String {
        switch it.kind {
        case .text:
            if it.text.isEmpty { return bytes(it.meta.byteSize) }
            return plural(it.meta.charCount, "caractère", "caractères")
                + (it.meta.lineCount > 1 ? " · " + plural(it.meta.lineCount, "ligne", "lignes") : "")
        case .link: return it.linkURL?.host ?? it.text
        case .image: return it.meta.imageWidth > 0 ? "\(it.meta.imageWidth) × \(it.meta.imageHeight)" : bytes(it.meta.byteSize)
        case .files:
            if it.meta.filePaths.count == 1 {
                let p = it.meta.filePaths[0]
                if let size = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int, size > 0,
                   !p.hasSuffix(".app") { return bytes(size) }
                return (p as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            }
            return plural(it.meta.filePaths.count, "fichier", "fichiers")
        case .color: return it.meta.colorHex ?? ""
        }
    }

    static func kindTitle(_ it: ClipItem) -> String {
        if let t = it.displayTitle { return t }
        switch it.kind {
        case .text: return it.text.isEmpty ? "Contenu" : (it.meta.isCode ? "Code" : (it.meta.isRich ? "Texte enrichi" : "Texte"))
        case .files: return it.meta.filePaths.count > 1 ? "\(it.meta.filePaths.count) fichiers" : "Fichier"
        default: return it.kind.label
        }
    }
}

/// Carte d'un élément dans la rangée horizontale.
struct CardView: View {
    let item: ClipItem
    let index: Int
    @ObservedObject var model: PanelModel
    var width: CGFloat = 236
    var height: CGFloat = 236

    private var isSelected: Bool { model.selectedID == item.id }
    private var headerColor: Color { Color(nsColor: AppInfo.color(item.appBundleID)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            CardContent(item: item, store: model.store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            footer
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 3.5 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0.14), radius: isSelected ? 10 : 5, y: 3)
        .scaleEffect(isSelected ? 1.0 : 0.985)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selectedID = item.id; model.paste() }
        .simultaneousGesture(TapGesture().onEnded { model.selectedID = item.id })
        .contextMenu { CardMenu(item: item, model: model) }
        .onDrag { dragProvider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Fmt.kindTitle(item)), \(item.appName ?? ""), \(Fmt.ago(item.lastUsed, now: model.now))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.kindTitle(item))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(Fmt.ago(item.lastUsed, now: model.now))
                    .font(.system(size: 11))
                    .opacity(0.82)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(nsImage: AppInfo.icon(item.appBundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 50)
        .background(headerColor.gradient)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if case .history = model.tab, let pid = item.pinboardID, let p = model.store.pinboards.first(where: { $0.id == pid }) {
                Circle().fill(p.color).frame(width: 7, height: 7).help("Épinglé dans « \(p.name) »")
            }
            Text(Fmt.footer(item))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if model.commandHeld, index < 9 {
                Text((model.shiftHeld ? "⇧⌘" : "⌘") + "\(index + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    /// Glisser une carte vers une autre app (ou sur un onglet de pinboard pour l'y épingler).
    private func dragProvider() -> NSItemProvider {
        model.draggingID = item.id
        let p = NSItemProvider()
        switch item.kind {
        case .files:
            if let url = item.fileURLs.first { return NSItemProvider(contentsOf: url) ?? p }
        case .image:
            let store = model.store, id = item.id
            p.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { done in
                Task { @MainActor in
                    let snap = store.snapshot(for: id)
                    let data = snap?.first(.png) ?? snap?.first(.tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
                    done(data, nil)
                }
                return nil
            }
            return p
        case .link:
            if let url = item.linkURL { return NSItemProvider(object: url as NSURL) }
        case .color:
            return NSItemProvider(object: (item.meta.colorHex ?? item.text) as NSString)
        case .text:
            break
        }
        return NSItemProvider(object: item.text as NSString)
    }
}

/// Corps de carte selon la nature de l'élément.
struct CardContent: View {
    let item: ClipItem
    let store: Store
    var large = false

    var body: some View {
        switch item.kind {
        case .text: textBody
        case .link: linkBody
        case .image: imageBody
        case .files: filesBody
        case .color: colorBody
        }
    }

    @ViewBuilder private var textBody: some View {
        if item.text.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Contenu de \(item.appName ?? "l'app")").font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(String(item.text.prefix(large ? 60_000 : 700)))
                .font(item.meta.isCode ? .system(size: large ? 13 : 11, design: .monospaced) : .system(size: large ? 14 : 12.5))
                .lineSpacing(item.meta.isCode ? 1 : 2)
                .fixedSize(horizontal: item.meta.isCode && !large, vertical: false)   // le code ne se replie pas : indentation intacte
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, maxHeight: large ? nil : .infinity, alignment: .topLeading)
                .padding(large ? 16 : 11)
                .mask(fade)
        }
    }

    private var fade: some View {
        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: large ? 1 : 0.78),
                               .init(color: .black.opacity(large ? 1 : 0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var linkBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let img = store.linkImage(for: item) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: large ? 320 : .infinity)
                    .overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.linkURL?.scheme == "mailto" ? "envelope" : "globe")
                        .font(.system(size: large ? 56 : 34, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: large ? 200 : .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meta.linkTitle ?? item.linkURL?.host ?? item.text)
                    .font(.system(size: large ? 15 : 12, weight: .semibold))
                    .lineLimit(large ? 3 : 2)
                Text(item.text)
                    .font(.system(size: large ? 12 : 10.5))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(large ? 4 : 1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, large ? 16 : 11)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder private var imageBody: some View {
        if let img = store.thumbnail(for: item) {
            ZStack {
                Checkerboard().opacity(0.5)
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(large ? 0 : 6)
            }
        } else {
            Image(systemName: "photo").font(.system(size: 34)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var filesBody: some View {
        let urls = item.fileURLs
        if urls.count == 1 {
            VStack(spacing: 8) {
                if let img = store.thumbnail(for: item) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(radius: 2, y: 1)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: urls[0].path))
                        .resizable().aspectRatio(contentMode: .fit).frame(width: large ? 128 : 72, height: large ? 128 : 72)
                }
                Text(urls[0].lastPathComponent)
                    .font(.system(size: large ? 14 : 12, weight: .medium))
                    .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                if !FileManager.default.fileExists(atPath: urls[0].path) {
                    Label("Introuvable", systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(large ? 20 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(urls.prefix(large ? 40 : 5).enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 7) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                }
                if urls.count > (large ? 40 : 5) {
                    Text("et \(urls.count - (large ? 40 : 5)) autres…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(large ? 16 : 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var colorBody: some View {
        let ns = NSColor(hex: item.meta.colorHex ?? "#000000")
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: ns)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.meta.colorHex ?? "").font(.system(size: large ? 22 : 15, weight: .semibold, design: .monospaced))
                if !large, item.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != item.meta.colorHex {
                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 11, design: .monospaced)).opacity(0.8)
                }
                if large { Text(ns.rgbDescription).font(.system(size: 12, design: .monospaced)).opacity(0.8) }
            }
            .foregroundStyle(ns.isLight ? Color.black.opacity(0.8) : Color.white)
            .padding(large ? 20 : 12)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

/// Menu contextuel d'une carte.
struct CardMenu: View {
    let item: ClipItem
    @ObservedObject var model: PanelModel

    var body: some View {
        Button("Coller") { model.selectedID = item.id; model.paste(plainText: false) }
        if item.kind == .text || item.kind == .link { Button("Coller en texte brut") { model.selectedID = item.id; model.paste(plainText: true) } }
        Button("Copier") { model.selectedID = item.id; model.copySelected() }
        Button("Aperçu") { model.selectedID = item.id; model.previewOpen = true }
        Divider()
        Menu("Épingler dans") {
            ForEach(model.store.pinboards) { p in
                Button { model.store.pin(item.id, to: p.id) } label: {
                    Text((item.pinboardID == p.id ? "✓ " : "") + p.name)
                }
            }
            if !model.store.pinboards.isEmpty { Divider() }
            Button("Nouveau pinboard…") { model.open(.newPinboard(pinItemID: item.id)) }
        }
        if item.pinboardID != nil { Button("Retirer du pinboard") { model.store.pin(item.id, to: nil) } }
        Button("Renommer…") { model.open(.renameItem(item.id)) }
        if item.kind == .text && !item.text.isEmpty || item.kind == .link || item.kind == .color {
            Button("Modifier le texte…") { model.open(.editText(item.id)) }
        }
        if let url = item.linkURL { Button("Ouvrir le lien") { NSWorkspace.shared.open(url); model.onClose?() } }
        if item.kind == .files { Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs); model.onClose?() } }
        Divider()
        Button("Supprimer", role: .destructive) { model.store.delete([item.id]) }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.62
    }

    var rgbDescription: String {
        guard let c = usingColorSpace(.sRGB) else { return "" }
        let r = Int(c.redComponent * 255 + 0.5), g = Int(c.greenComponent * 255 + 0.5), b = Int(c.blueComponent * 255 + 0.5)
        return "rgb(\(r), \(g), \(b))  ·  hsb(\(Int(c.hueComponent * 360)), \(Int(c.saturationComponent * 100))%, \(Int(c.brightnessComponent * 100))%)"
    }
}
