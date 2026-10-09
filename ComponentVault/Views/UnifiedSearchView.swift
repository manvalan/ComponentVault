import SwiftUI
import SwiftData

// MARK: - Le tre spie

/// Stato di una spia: acceso (verde), parziale (arancio), spento (vuoto), non noto (grigio).
enum PartLight: Equatable {
    case on, partial, off, unknown

    var color: Color {
        switch self {
        case .on: .green
        case .partial: .orange
        case .off: .secondary.opacity(0.5)
        case .unknown: .secondary.opacity(0.25)
        }
    }
}

/// Magazzino · KiCad · Mercato: le tre domande su ogni componente.
struct PartLights: View {
    let stock: PartLight
    let kicad: PartLight
    let market: PartLight
    var help: [String] = []

    var body: some View {
        HStack(spacing: 4) {
            dot(stock, systemImage: "shippingbox.fill")
            dot(kicad, systemImage: "cpu.fill")
            dot(market, systemImage: "cart.fill")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.joined(separator: ", "))
        .help(help.joined(separator: " · "))
    }

    private func dot(_ light: PartLight, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(light == .off || light == .unknown ? Color.secondary.opacity(0.6) : .white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(light == .off || light == .unknown ? Color.clear : light.color))
            .overlay(Circle().strokeBorder(light.color, lineWidth: light == .off || light == .unknown ? 1.2 : 0))
    }
}

// MARK: - Risultato unificato

/// Un componente trovato: può essere in magazzino, nella libreria KiCad, online, o più cose insieme.
struct PartHit: Identifiable {
    let id: String
    var component: Component?
    var kicad: KiCadLibraryEntry?
    var card: CatalogMatchCard?

    var mpn: String {
        if let component, !component.mpn.isEmpty { return component.mpn }
        if let card, !card.mpn.isEmpty { return card.mpn }
        return kicad?.mpn ?? ""
    }

    var title: String {
        if let component { return component.displayTitle }
        if !mpn.isEmpty { return mpn }
        return kicad?.name ?? card?.lcscCode ?? "—"
    }

    var subtitle: String {
        var parts: [String] = []
        if let component {
            parts += [component.brand, component.value, component.footprint]
        } else if let card {
            parts += [card.brand, card.description]
        } else if let kicad {
            parts += [kicad.lib, kicad.footprint ?? ""]
        }
        return parts.filter { !$0.isEmpty && $0 != "—" }.joined(separator: " · ")
    }

    var lcsc: String? { component?.supplierLCSCCode ?? card?.lcscCode ?? kicad?.lcsc }
}

// MARK: - Cerca

/// La home: un campo solo per magazzino, libreria KiCad e distributori.
struct UnifiedSearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var inventory: [Component]
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    @State private var query = ""
    @State private var library = KiCadLibraryStore.shared
    @State private var store: ComponentStore?
    @State private var projectStore: ProjectStore?
    @State private var provider = SupplierCatalogSearchService.effective(AppConfigIO.current().catalog.searchProvider)

    @State private var online: [CatalogMatchCard] = []
    @State private var onlineMessage: String?
    @State private var isSearchingOnline = false
    @State private var searchedOnline = false
    @State private var searchedAll = false

    @State private var openedComponent: Component?
    @State private var kicadItems: [KiCadFetchItem]?
    @State private var showScan = false
    @State private var toast: String?
    @State private var busyHit: String?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if trimmed.isEmpty {
                    home
                } else {
                    results
                }
            }
            .navigationTitle("Cerca")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem {
                    Button {
                        showScan = true
                    } label: {
                        Label("Carica da etichetta", systemImage: "barcode.viewfinder")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .task { await library.refresh() }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            if projectStore == nil { projectStore = ProjectStore(modelContext: modelContext) }
            provider = SupplierCatalogSearchService.effective(AppConfigIO.current().catalog.searchProvider)
            fieldFocused = true
        }
        .task(id: query) {
            online = []
            onlineMessage = nil
            searchedOnline = false
            searchedAll = false
            // Online solo per un MPN o quando in locale non c'è nulla: le chiamate API costano.
            guard trimmed.count >= 3,
                  CatalogSearchQuery.looksLikeMPN(trimmed) || localHits.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await searchOnline(all: false)
        }
        .sheet(item: $openedComponent) { component in
            ComponentDetailSheet(component: component, store: store)
        }
        .sheet(isPresented: Binding(get: { kicadItems != nil }, set: { if !$0 { kicadItems = nil } })) {
            if let kicadItems {
                KiCadFetchView(items: kicadItems, title: String(localized: "Aggiungi a KiCad"))
            }
        }
        .sheet(isPresented: $showScan) {
            ScanImportView()
        }
    }

    // MARK: Campo

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("MPN, valore, codice LCSC, cassetto…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await searchOnline(all: false) } }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Button("") { fieldFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
        )
    }

    // MARK: Home (campo vuoto)

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    summaryTile(value: "\(inventory.count)", label: "in magazzino", systemImage: "shippingbox.fill")
                    summaryTile(value: library.index.map { "\($0.count)" } ?? "—", label: "in \(library.displayName)", systemImage: "cpu.fill")
                    summaryTile(value: provider.label, label: "fornitore predefinito", systemImage: "cart.fill")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Le tre spie").font(.headline)
                    legendRow(.on, "Verde: c'è (in magazzino, in libreria con 3D, disponibile).")
                    legendRow(.partial, "Arancio: quasi (scorta bassa, manca il 3D).")
                    legendRow(.off, "Vuota: manca. Usa i pulsanti della riga per rimediare.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prova").font(.headline)
                    HStack(spacing: 8) {
                        ForEach(["TLV62569", "10k 0603", "C25804", "A·12"], id: \.self) { sample in
                            Button(sample) { query = sample }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryTile(value: String, label: LocalizedStringKey, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(.tint)
            Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func legendRow(_ light: PartLight, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            PartLights(stock: light, kicad: light, market: light)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Risultati

    private var results: some View {
        let local = localHits
        let onlineOnly = onlineHits(excluding: local)
        return List {
            Section {
                if local.isEmpty {
                    Text("Niente in magazzino né in libreria.").foregroundStyle(.secondary)
                }
                ForEach(local) { hit in row(hit) }
            } header: {
                Text("Magazzino e libreria")
            }

            Section {
                if isSearchingOnline {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Cerco su \(searchedAll ? String(localized: "tutti i fornitori") : provider.label)…")
                            .foregroundStyle(.secondary)
                    }
                } else if !searchedOnline {
                    Button {
                        Task { await searchOnline(all: false) }
                    } label: {
                        Label("Cerca «\(trimmed)» su \(provider.label)", systemImage: "network")
                    }
                }
                if let onlineMessage {
                    Text(onlineMessage).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(onlineOnly) { hit in row(hit) }
                let others = SupplierCatalogSearchService.otherSuppliers(than: provider)
                if searchedOnline, !searchedAll, !others.isEmpty, !isSearchingOnline {
                    Button {
                        Task { await searchOnline(all: true) }
                    } label: {
                        Label("Cerca anche su \(others.joined(separator: ", "))", systemImage: "plus.magnifyingglass")
                    }
                }
            } header: {
                Text("Online")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    private func row(_ hit: PartHit) -> some View {
        let lights = lights(for: hit)
        return HStack(spacing: 12) {
            PartLights(stock: lights.stock, kicad: lights.kicad, market: lights.market, help: lights.help)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.body.monospaced()).lineLimit(1)
                let detail = [hit.subtitle, hit.component?.storageLabel.map { "📦 \($0)" }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if busyHit == hit.id {
                ProgressView().controlSize(.small)
            } else {
                actions(for: hit, lights: lights)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let component = hit.component { openedComponent = component }
        }
    }

    @ViewBuilder
    private func actions(for hit: PartHit, lights: (stock: PartLight, kicad: PartLight, market: PartLight, help: [String])) -> some View {
        HStack(spacing: 6) {
            if lights.kicad == .off, !hit.mpn.isEmpty, KiCadQueue.isAvailable {
                Button {
                    kicadItems = [KiCadFetchItem(
                        mpn: String(hit.mpn.prefix(128)),
                        lcsc: hit.lcsc,
                        funzione: String((hit.component?.category ?? hit.card?.description ?? "").prefix(256))
                    )]
                } label: {
                    Label("KiCad", systemImage: "arrow.down.circle")
                }
                .help("Scarica simbolo, footprint e modello 3D nella libreria")
            }
            if hit.component == nil {
                Button {
                    Task { await addToInventory(hit) }
                } label: {
                    Label("Magazzino", systemImage: "plus.circle")
                }
                .help("Aggiungi al magazzino (stock 0, da ordinare)")
            }
            Menu {
                if projects.isEmpty {
                    Text("Nessun progetto")
                }
                ForEach(projects) { project in
                    Button(project.name) { Task { await addToProject(hit, project: project) } }
                }
            } label: {
                Label("BOM", systemImage: "list.bullet.rectangle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func lights(for hit: PartHit) -> (stock: PartLight, kicad: PartLight, market: PartLight, help: [String]) {
        var help: [String] = []

        let stock: PartLight
        if let component = hit.component {
            if component.quantity <= 0 {
                stock = .off
                help.append(String(localized: "Magazzino: 0"))
            } else if component.isLowStock {
                stock = .partial
                help.append(String(localized: "Magazzino: \(component.quantity), scorta bassa"))
            } else {
                stock = .on
                help.append(String(localized: "Magazzino: \(component.quantity)"))
            }
        } else {
            stock = .off
            help.append(String(localized: "Non in magazzino"))
        }

        let kicad: PartLight
        let entry = hit.kicad ?? {
            if case .present(let found) = library.match(mpn: hit.mpn, lcsc: hit.lcsc) { return found }
            return nil
        }()
        if let entry {
            kicad = entry.model3d == false ? .partial : .on
            help.append(entry.model3d == false
                        ? String(localized: "KiCad: \(entry.lib), senza 3D")
                        : String(localized: "KiCad: \(entry.lib)"))
        } else if library.index == nil {
            kicad = .unknown
            help.append(String(localized: "KiCad: indice non disponibile"))
        } else {
            kicad = .off
            help.append(String(localized: "Non in libreria KiCad"))
        }

        let market: PartLight
        let marketStock = hit.card?.offer?.stock ?? hit.card?.lcscStock ?? hit.component?.supplierStock
        if let marketStock {
            market = marketStock > 0 ? .on : .off
            help.append(String(localized: "Mercato: \(marketStock) disponibili"))
        } else {
            market = .unknown
            help.append(String(localized: "Mercato: non noto"))
        }
        return (stock, kicad, market, help)
    }

    // MARK: Ricerca

    /// Magazzino (tutte le parole devono comparire) più i simboli della libreria KiCad, uniti per MPN.
    private var localHits: [PartHit] {
        let terms = trimmed.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }

        var hits: [PartHit] = []
        var byKey: [String: Int] = [:]

        for component in inventory {
            let haystack = [
                component.lcscCode, component.supplierLCSCCode ?? "", component.mpn, component.name,
                component.value, component.footprint, component.brand, component.componentDescription,
                component.category, component.storageLabel ?? "", component.tags.joined(separator: " "),
            ].joined(separator: " ").lowercased()
            guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
            let key = KiCadLibraryStore.normalize(component.mpn)
            if !key.isEmpty { byKey[key] = hits.count }
            hits.append(PartHit(id: "inv:" + component.lcscCode, component: component))
            if hits.count >= 60 { break }
        }

        for entry in library.search(trimmed, ownOnly: false, limit: 30) {
            let key = KiCadLibraryStore.normalize(entry.mpn ?? entry.name)
            if let index = byKey[key] {
                hits[index].kicad = entry
            } else {
                if !key.isEmpty { byKey[key] = hits.count }
                hits.append(PartHit(id: "kicad:" + entry.id, kicad: entry))
            }
        }
        return hits
    }

    private func onlineHits(excluding local: [PartHit]) -> [PartHit] {
        let localKeys = Set(local.map { KiCadLibraryStore.normalize($0.mpn) }.filter { !$0.isEmpty })
        var seen = Set<String>()
        return online.compactMap { card in
            let key = KiCadLibraryStore.normalize(card.mpn)
            guard !localKeys.contains(key) || key.isEmpty else { return nil }
            // Una riga per MPN: la prima offerta (fornitore predefinito) vince.
            if !key.isEmpty, !seen.insert(key).inserted { return nil }
            return PartHit(id: "web:" + card.id, card: card)
        }
    }

    private func searchOnline(all: Bool) async {
        guard !trimmed.isEmpty else { return }
        isSearchingOnline = true
        searchedAll = all
        defer {
            isSearchingOnline = false
            searchedOnline = true
        }
        let searchQuery = CatalogSearchQuery(type: nil, valueAmount: trimmed)
        do {
            let outcome = try await SupplierCatalogSearchService.search(
                query: searchQuery,
                inventory: inventory,
                provider: provider,
                allSuppliers: all
            )
            online = outcome.cards
            onlineMessage = outcome.statusMessage
        } catch {
            onlineMessage = error.localizedDescription
        }
    }

    // MARK: Azioni

    /// Porta in magazzino un risultato online o della libreria (stock 0, da ordinare).
    @discardableResult
    private func ensureComponent(_ hit: PartHit) async -> Component? {
        if let component = hit.component { return component }
        guard let store else { return nil }
        busyHit = hit.id
        defer { busyHit = nil }
        do {
            if let card = hit.card {
                return try await store.importCatalogMatch(card)
            }
            let code = hit.mpn.isEmpty ? (hit.lcsc ?? "") : hit.mpn
            guard let label = LabelParser.parse(code) else { return nil }
            return try await store.receiveScanned(label, quantity: 0, location: "", slot: "").component
        } catch {
            showToast(error.localizedDescription)
            return nil
        }
    }

    private func addToInventory(_ hit: PartHit) async {
        if let component = await ensureComponent(hit) {
            showToast(String(localized: "\(component.displayTitle) in magazzino, da ordinare"))
        }
    }

    private func addToProject(_ hit: PartHit, project: Project) async {
        guard let component = await ensureComponent(hit) else { return }
        do {
            try projectStore?.addComponent(component, to: project)
            showToast(String(localized: "\(component.displayTitle) aggiunto a \(project.name)"))
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.snappy) { if toast == message { toast = nil } }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
