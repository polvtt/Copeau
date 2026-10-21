import AppKit
import Combine

enum Tab: Equatable, Hashable {
    case history
    case pinboard(String)

    var key: String {
        switch self { case .history: "history"; case .pinboard(let id): id }
    }
}

enum Dialog: Equatable {
    case renameItem(String)
    case editText(String)
    case newText
    case newPinboard(pinItemID: String?)
    case renamePinboard(String)
    case confirmDeletePinboard(String)
}

/// État du panneau principal (recherche, onglet, sélection, dialogues) et actions clavier.
@MainActor
final class PanelModel: ObservableObject {
    let store: Store
    let settings: Settings
    let monitor: ClipboardMonitor

    @Published var query = ""
    @Published var tab: Tab = .history
    @Published var kindFilter: ClipKind?
    @Published var selectedID: String?
    @Published private(set) var visible: [ClipItem] = []
    @Published var commandHeld = false
    @Published var shiftHeld = false
    @Published var previewOpen = false
    @Published var dialog: Dialog?
    @Published var dialogText = ""
    @Published var dialogColor = 0
    @Published var now = Date()
    @Published var focusToken = 0
    @Published var showToken = 0
    @Published var draggingID: String?
    @Published var accessibilityGranted = Colleur.isTrusted

    // Branché par le contrôleur du panneau.
    var onPaste: ((ClipItem, Bool) -> Void)?
    var onCopy: ((ClipItem) -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onResize: ((Double) -> Void)?

    private var bag: Set<AnyCancellable> = []

    init(store: Store, settings: Settings, monitor: ClipboardMonitor) {
        self.store = store
        self.settings = settings
        self.monitor = monitor
        if let last = settings.lastTab, last != "history", store.pinboards.contains(where: { $0.id == last }) {
            tab = .pinboard(last)
        }
        Publishers.CombineLatest4(store.$items, $query.removeDuplicates(), $tab, $kindFilter)
            .sink { [weak self] items, query, tab, kind in self?.recompute(items, query, tab, kind) }
            .store(in: &bag)
        store.$pinboards
            .sink { [weak self] boards in
                guard let self, case .pinboard(let id) = self.tab, !boards.contains(where: { $0.id == id }) else { return }
                self.tab = .history
            }
            .store(in: &bag)
        $tab.dropFirst().sink { settings.lastTab = $0.key }.store(in: &bag)
        // Les réglages imbriqués ne propagent pas leurs changements : on relaie ceux qui touchent l'affichage.
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        monitor.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    private func recompute(_ items: [ClipItem], _ query: String, _ tab: Tab, _ kind: ClipKind?) {
        let tokens = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(separator: " ").map(String.init)
        visible = items.filter { it in
            if case .pinboard(let id) = tab, it.pinboardID != id { return false }
            if let kind, it.kind != kind { return false }
            return tokens.isEmpty || it.matches(tokens)
        }
        if selectedID == nil || !visible.contains(where: { $0.id == selectedID }) {
            selectedID = visible.first?.id
        }
    }

    var selected: ClipItem? { visible.first { $0.id == selectedID } ?? visible.first }
    var selectedIndex: Int? { visible.firstIndex { $0.id == selectedID } }

    var currentPinboard: Pinboard? {
        if case .pinboard(let id) = tab { return store.pinboards.first { $0.id == id } }
        return nil
    }

    /// Appelé à chaque ouverture : recherche vide, première carte sélectionnée.
    func prepareForShow() {
        query = ""
        kindFilter = nil
        dialog = nil
        previewOpen = false
        commandHeld = false
        shiftHeld = false
        now = Date()
        accessibilityGranted = Colleur.isTrusted
        monitor.refreshAccess()
        selectedID = visible.first?.id
        focusToken += 1
        showToken += 1
    }

    // MARK: - Actions

    func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let i = selectedIndex ?? 0
        selectedID = visible[min(max(i + delta, 0), visible.count - 1)].id
    }

    func selectFirst() { selectedID = visible.first?.id }
    func selectLast() { selectedID = visible.last?.id }

    func paste(plainText: Bool? = nil) {
        guard let it = selected else { NSSound.beep(); return }
        onPaste?(it, plainText ?? settings.plainTextByDefault)
    }

    /// ⌘1…⌘9 : colle la n-ième carte visible.
    func quickPaste(_ n: Int, plainText: Bool) {
        guard visible.indices.contains(n) else { NSSound.beep(); return }
        selectedID = visible[n].id
        onPaste?(visible[n], plainText != settings.plainTextByDefault)
    }

    func copySelected() {
        guard let it = selected else { return }
        onCopy?(it)
    }

    func deleteSelected() {
        guard let it = selected else { return }
        let i = selectedIndex ?? 0
        store.delete([it.id])
        if !visible.isEmpty { selectedID = visible[min(i, visible.count - 1)].id }
    }

    func togglePreview() {
        guard selected != nil || previewOpen else { return }
        previewOpen.toggle()
    }

    var tabs: [Tab] { [.history] + store.pinboards.map { .pinboard($0.id) } }

    func cycleTab(_ delta: Int) {
        let all = tabs
        guard let i = all.firstIndex(of: tab) else { tab = .history; return }
        tab = all[(i + delta + all.count) % all.count]
        selectFirst()
    }

    func clearSearchOrClose() {
        if previewOpen { previewOpen = false } else if !query.isEmpty || kindFilter != nil { query = ""; kindFilter = nil } else { onClose?() }
    }

    // MARK: - Dialogues

    func open(_ d: Dialog) {
        switch d {
        case .renameItem(let id): dialogText = store.item(id)?.title ?? ""
        case .editText(let id): dialogText = store.item(id)?.text ?? ""
        case .newText: dialogText = ""
        case .newPinboard: dialogText = ""; dialogColor = store.pinboards.count % Palette.colors.count
        case .renamePinboard(let id):
            dialogText = store.pinboards.first { $0.id == id }?.name ?? ""
            dialogColor = store.pinboards.first { $0.id == id }?.colorIndex ?? 0
        case .confirmDeletePinboard: break
        }
        previewOpen = false
        dialog = d
    }

    func confirmDialog() {
        guard let d = dialog else { return }
        let text = dialogText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch d {
        case .renameItem(let id): store.rename(id, to: text)
        case .editText(let id): if !dialogText.isEmpty { store.updateText(id, dialogText) }
        case .newText:
            if !dialogText.isEmpty, let it = store.addText(dialogText, pinboardID: currentPinboard?.id) { selectedID = it.id }
        case .newPinboard(let itemID):
            let p = store.createPinboard(name: text.isEmpty ? "Pinboard" : text, colorIndex: dialogColor)
            if let itemID { store.pin(itemID, to: p.id) } else { tab = .pinboard(p.id) }
        case .renamePinboard(let id): store.updatePinboard(id, name: text.isEmpty ? nil : text, colorIndex: dialogColor)
        case .confirmDeletePinboard(let id): store.deletePinboard(id)
        }
        dialog = nil
        focusToken += 1
    }

    func cancelDialog() {
        dialog = nil
        focusToken += 1
    }
}
