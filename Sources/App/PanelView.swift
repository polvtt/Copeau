import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Contenu du panneau : barre (recherche, filtre, onglets), bandeaux d'autorisation,
/// rangée de cartes, dialogues.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: Store

    init(model: PanelModel) {
        self.model = model
        self.store = model.store
    }

    var body: some View {
        VStack(spacing: 0) {
            ResizeHandle(model: model)
            TopBar(model: model, store: store)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            Banners(model: model)
            Strip(model: model)
        }
        .overlay { if model.dialog != nil { DialogOverlay(model: model) } }
    }
}

// MARK: - Barre du haut

struct TopBar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 14, weight: .medium))
                SearchField(model: model).frame(height: 22)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Effacer la recherche")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 280, height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))

            KindFilterMenu(model: model)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    TabChip(model: model, tab: .history, title: "Historique", color: nil, symbol: "clock")
                    ForEach(store.pinboards) { p in
                        TabChip(model: model, tab: .pinboard(p.id), title: p.name, color: p.color, symbol: nil)
                    }
                    Button { model.open(.newPinboard(pinItemID: nil)) } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Nouveau pinboard")
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            if model.monitor.isPaused {
                Label("En pause", systemImage: "pause.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .onTapGesture { model.monitor.isPaused = false }
                    .help("La capture est en pause. Cliquer pour reprendre.")
            }

            Menu {
                Button("Nouvel élément texte…") { model.open(.newText) }
                Divider()
                Button(model.monitor.isPaused ? "Reprendre la capture" : "Mettre la capture en pause") { model.monitor.isPaused.toggle() }
                Button("Ignorer la prochaine copie") { model.monitor.ignoreNextCopy() }
                Divider()
                Button("Réglages…") { model.onOpenSettings?() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help("Options")
        }
        .frame(height: 36)
    }
}

struct KindFilterMenu: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            Button { model.kindFilter = nil } label: { Text((model.kindFilter == nil ? "✓ " : "") + "Tous les types") }
            Divider()
            ForEach(ClipKind.allCases) { k in
                Button { model.kindFilter = k } label: { Label((model.kindFilter == k ? "✓ " : "") + k.pluralLabel, systemImage: k.symbol) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.kindFilter?.symbol ?? "line.3.horizontal.decrease.circle")
                if let k = model.kindFilter { Text(k.pluralLabel).font(.system(size: 12, weight: .medium)) }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.kindFilter == nil ? Color.secondary : Color.accentColor)
        .help("Filtrer par type")
    }
}

struct TabChip: View {
    @ObservedObject var model: PanelModel
    let tab: Tab
    let title: String
    let color: Color?
    let symbol: String?

    private var isActive: Bool { model.tab == tab }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            if let color { Circle().fill(color).frame(width: 9, height: 9) }
            Text(title).font(.system(size: 13, weight: isActive ? .semibold : .regular)).lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule().fill(isActive ? Color.primary.opacity(0.12) : Color.clear))
        .contentShape(Capsule())
        .onTapGesture { model.tab = tab; model.selectFirst(); model.focusToken += 1 }
        .onDrop(of: [UTType.data.identifier], isTargeted: nil) { _ in
            // Une carte glissée sur un onglet de pinboard y est épinglée (sur « Historique » : retirée).
            guard let id = model.draggingID else { return false }
            if case .pinboard(let pid) = tab { model.store.pin(id, to: pid) } else { model.store.pin(id, to: nil) }
            model.draggingID = nil
            return true
        }
        .contextMenu {
            if case .pinboard(let id) = tab {
                Button("Renommer ou changer la couleur…") { model.open(.renamePinboard(id)) }
                Button("Déplacer à gauche") { model.store.movePinboard(id, by: -1) }
                Button("Déplacer à droite") { model.store.movePinboard(id, by: 1) }
                Divider()
                Button("Supprimer le pinboard…", role: .destructive) { model.open(.confirmDeletePinboard(id)) }
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }
}

// MARK: - Bandeaux

struct Banners: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 6) {
            if model.monitor.access == .denied {
                Banner(symbol: "hand.raised.fill", tint: .red,
                       text: "macOS refuse à Copeau la lecture du presse-papiers : plus rien n'est capturé.",
                       action: "Autoriser…") { Links.openPasteboardPrivacy(); model.onClose?() }
            } else if model.monitor.access == .ask {
                Banner(symbol: "questionmark.circle.fill", tint: .orange,
                       text: "macOS demande une confirmation à chaque copie. Choisis « Toujours autoriser » pour Copeau.",
                       action: "Ouvrir Réglages") { Links.openPasteboardPrivacy(); model.onClose?() }
            }
            if model.settings.directPaste && !model.accessibilityGranted {
                Banner(symbol: "keyboard", tint: .blue,
                       text: "Sans l'Accessibilité, Copeau copie l'élément mais ne peut pas le coller à ta place.",
                       action: "Autoriser…") { Colleur.requestTrust(); Links.openAccessibilityPrivacy(); model.onClose?() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button(action, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.12)))
    }
}

enum Links {
    static func openPasteboardPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
    }
    static func openAccessibilityPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Rangée de cartes

struct Strip: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        GeometryReader { geo in
            let side = max(150, min(geo.size.height - 22, 330))
            if model.visible.isEmpty {
                EmptyState(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(Array(model.visible.enumerated()), id: \.element.id) { i, item in
                                CardView(item: item, index: i, model: model, width: side, height: side).id(item.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    .onChange(of: model.showToken) { _, _ in
                        if let id = model.visible.first?.id { proxy.scrollTo(id, anchor: .leading) }
                    }
                }
            }
        }
    }
}

struct EmptyState: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.bottom, 20)
    }

    private var searching: Bool { !model.query.isEmpty || model.kindFilter != nil }
    private var icon: String { searching ? "magnifyingglass" : (model.currentPinboard != nil ? "pin" : "doc.on.clipboard") }
    private var title: String {
        if searching { return "Aucun résultat" }
        if let p = model.currentPinboard { return "« \(p.name) » est vide" }
        return "Rien de copié pour l'instant"
    }
    private var subtitle: String {
        if searching { return "Essaie d'autres mots, ou retire le filtre de type." }
        if model.currentPinboard != nil { return "Glisse une carte sur cet onglet, ou clic droit › Épingler dans." }
        return "Copie du texte, une image ou des fichiers (⌘C) : ils apparaîtront ici."
    }
}

/// Bord supérieur : glisser pour changer la hauteur du panneau.
struct ResizeHandle: View {
    @ObservedObject var model: PanelModel
    @StateObject private var drag = DragState()

    final class DragState: ObservableObject { var start: Double? }

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    let start = drag.start ?? model.settings.panelHeight
                    drag.start = start
                    model.onResize?(start - v.translation.height)
                }
                .onEnded { _ in drag.start = nil })
            .help("Glisser pour redimensionner")
    }
}

// MARK: - Dialogues

struct DialogOverlay: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).onTapGesture { model.cancelDialog() }
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content
                HStack {
                    Spacer()
                    Button("Annuler") { model.cancelDialog() }.keyboardShortcut(.cancelAction)
                    Button(confirmLabel) { model.confirmDialog() }
                        .keyboardShortcut(isMultiline ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(isDestructive ? .red : .accentColor)
                }
            }
            .padding(18)
            .frame(width: isMultiline ? 560 : 380)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 20)
        }
    }

    private var isMultiline: Bool {
        switch model.dialog { case .editText, .newText: true; default: false }
    }
    private var isDestructive: Bool { if case .confirmDeletePinboard = model.dialog { return true }; return false }

    private var title: String {
        switch model.dialog {
        case .renameItem: "Renommer l'élément"
        case .editText: "Modifier le texte"
        case .newText: model.currentPinboard.map { "Nouvel élément dans « \($0.name) »" } ?? "Nouvel élément texte"
        case .newPinboard: "Nouveau pinboard"
        case .renamePinboard: "Modifier le pinboard"
        case .confirmDeletePinboard(let id):
            "Supprimer « \(model.store.pinboards.first { $0.id == id }?.name ?? "") » ?"
        case nil: ""
        }
    }

    private var confirmLabel: String {
        switch model.dialog {
        case .newPinboard, .newText: "Créer"
        case .confirmDeletePinboard: "Supprimer"
        default: "Enregistrer"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.dialog {
        case .renameItem:
            DialogField(text: $model.dialogText, placeholder: "Titre (vide : titre automatique)",
                        onSubmit: model.confirmDialog, onCancel: model.cancelDialog)
        case .editText, .newText:
            DialogTextView(text: $model.dialogText, onSubmit: model.confirmDialog, onCancel: model.cancelDialog)
                .frame(height: 180)
            Text("⌘↩ pour enregistrer").font(.system(size: 11)).foregroundStyle(.secondary)
        case .newPinboard, .renamePinboard:
            DialogField(text: $model.dialogText, placeholder: "Nom du pinboard",
                        onSubmit: model.confirmDialog, onCancel: model.cancelDialog)
            HStack(spacing: 8) {
                ForEach(Palette.colors.indices, id: \.self) { i in
                    Circle().fill(Palette.colors[i]).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: model.dialogColor == i ? 2 : 0).padding(-3))
                        .onTapGesture { model.dialogColor = i }
                        .accessibilityLabel("Couleur \(i + 1)")
                }
            }
            .padding(.leading, 3)
        case .confirmDeletePinboard:
            Text("Ses éléments retournent dans l'historique, rien n'est effacé.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case nil: EmptyView()
        }
    }
}
