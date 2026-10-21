import AppKit
import SwiftUI

/// Aperçu agrandi de la carte sélectionnée (barre d'espace), au-dessus du panneau.
struct PreviewView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if let item = model.selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: AppInfo.icon(item.appBundleID)).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.kindTitle(item)).font(.system(size: 14, weight: .semibold))
                        Text(subtitle(item)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.footer(item)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                Divider()
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        CardContent(item: item, store: model.store, large: true)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                Divider()
                HStack(spacing: 16) {
                    hint("↩", "Coller")
                    hint("⇧↩", "Texte brut")
                    hint("← →", "Élément voisin")
                    Spacer()
                    hint("Espace", "Fermer")
                }
                .padding(.horizontal, 16)
                .frame(height: 34)
            }
        }
    }

    private func subtitle(_ it: ClipItem) -> String {
        var parts = [it.appName ?? "App inconnue", "copié le " + Fmt.dateTime.string(from: it.created)]
        if it.lastUsed.timeIntervalSince(it.created) > 60 { parts.append("utilisé " + Fmt.ago(it.lastUsed, now: model.now)) }
        if it.meta.isRemote { parts.append("presse-papiers universel") }
        return parts.joined(separator: " · ")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Bulle d'information brève (« Copié »), au-dessus du Dock.
struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .fixedSize()
    }
}
