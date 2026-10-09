import SwiftUI
import SwiftData

struct ComponentDetailView: View {
    @Bindable var component: Component
    var store: ComponentStore?
    var onReplaced: ((Component) -> Void)? = nil

    @Query(sort: \Component.lcscCode) private var inventory: [Component]

    @State private var selectedImageIndex = 0
    @State private var isEnriching = false
    @State private var digiKeyCandidates: [DigiKeyCandidate]?
    @State private var errorMessage: String?
    @State private var mpnLookupResults: [CatalogMatchCard] = []
    @State private var showMPNLookup = false
    @State private var mpnLookupTitle = ""
    @State private var isLookingUpMPN = false
    @State private var isLookingUpEquivalent = false
    @State private var infoMessage: String?
    @State private var showKiCadExport = false
    @State private var showKiCadFetch = false
    @State private var kicadExportDocument = CSVDocument()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if component.isToOrder {
                    toOrderBanner
                }
                header
                if component.needsLCSCForEasyEDA {
                    lcscResolutionBanner
                }
                HStack(alignment: .top, spacing: 24) {
                    imageGallery
                    inventoryCard
                }
                SupplierOffersSection(mpn: component.mpn, quantity: max(component.minQuantity, 1))
                descriptionSection
                tagsSection
                parametersSection
                stockHistorySection
                linksSection
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(component.displayTitle)
        .onAppear {
            component.migrateLegacySnapshotsIfNeeded()
            guard component.needsLCSCForEasyEDA,
                  let store else { return }
            let originalID = component.persistentModelID
            Task {
                do {
                    if let updated = try await store.assignLCSCFromMPN(component) {
                        handleReplacement(updated, originalID: originalID)
                    }
                } catch {
                    // Ricerca live non disponibile o nessun match: l'utente può usare «Trova LCSC».
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await enrich(source: .lcsc) }
                } label: {
                    if isEnriching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("LCSC", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isEnriching || store == nil)

                // Solo se l'utente ha inserito le proprie credenziali DigiKey su questo dispositivo.
                if DigiKeyKeychain.isConfigured {
                    Button {
                        Task { await enrichFromDigiKey() }
                    } label: {
                        Label("DigiKey", systemImage: "dollarsign.circle")
                    }
                    .disabled(isEnriching || store == nil || component.mpn.isEmpty)
                }

                if !component.mpn.isEmpty {
                    Button {
                        Task { await lookupLCSCFromMPN() }
                    } label: {
                        if isLookingUpMPN {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Trova LCSC", systemImage: "number")
                        }
                    }
                    .disabled(isLookingUpMPN)
                    .platformHelp("Cerca codice LCSC Cxxxxx per EasyEDA dal MPN \(component.mpn)")
                }

                if let lcsc = component.supplierLCSCCode {
                    Button {
                        PlatformPasteboard.copy(lcsc)
                    } label: {
                        Label("Copia LCSC", systemImage: "doc.on.doc")
                    }
                    .platformHelp("Copia \(lcsc) per EasyEDA")
                }

                if let lcscURL = component.lcscProductURL {
                    Link(destination: lcscURL) {
                        Label("Apri su LCSC", systemImage: "safari")
                    }
                }

                Menu {
                    Button {
                        kicadExportDocument = CSVDocument(
                            text: KiCadExportService.libraryFileContent(for: component)
                        )
                        showKiCadExport = true
                    } label: {
                        Label("Esporta file .kicad_sym", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showKiCadFetch = true
                    } label: {
                        Label("Scarica in \(KiCadLibraryStore.shared.displayName)…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(component.mpn.isEmpty || !KiCadQueue.isAvailable)
                } label: {
                    Label("KiCad", systemImage: "books.vertical")
                }
                .platformHelp("Esporta simbolo KiCad con LCSC, MPN e produttore")
            }
        }
        .fileExporter(
            isPresented: $showKiCadExport,
            document: kicadExportDocument,
            contentType: .plainText,
            defaultFilename: "\(KiCadExportService.symbolName(for: component)).kicad_sym"
        ) { _ in }
        .sheet(isPresented: Binding(
            get: { digiKeyCandidates != nil },
            set: { if !$0 { digiKeyCandidates = nil } }
        )) {
            DigiKeyCandidateSheet(
                candidates: digiKeyCandidates ?? [],
                onSelect: { candidate in
                    digiKeyCandidates = nil
                    Task { await applyDigiKeyCandidate(candidate) }
                },
                onCancel: { digiKeyCandidates = nil }
            )
        }
        .sheet(isPresented: $showMPNLookup) {
            mpnLookupSheet
        }
        .sheet(isPresented: $showKiCadFetch) {
            KiCadFetchView(component: component)
        }
        .alert("Errore", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("LCSC", isPresented: .constant(infoMessage != nil)) {
            Button("OK") { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
    }

    private func handleReplacement(_ updated: Component, originalID: PersistentIdentifier) {
        if updated.persistentModelID != originalID {
            onReplaced?(updated)
            infoMessage = String(localized: "Codice LCSC assegnato: \(updated.supplierLCSCCode ?? updated.lcscCode)")
        } else if updated.supplierLCSCCode != component.supplierLCSCCode {
            onReplaced?(updated)
            infoMessage = String(localized: "Codice LCSC assegnato: \(updated.supplierLCSCCode ?? updated.lcscCode)")
        }
    }

    private var toOrderBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cart.badge.clock")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Da ordinare")
                    .font(.headline)
                Text("Non presente in magazzino. La scheda è salvata per riferimento; lo stock LCSC è del fornitore, non del tuo inventario.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Prima di tutto: che cos'è. MPN grande, produttore e descrizione breve,
    /// poi i codici e lo stato in piccolo.
    private var header: some View {
        let type = component.componentType
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: type.icon)
                    .font(.title2)
                    .foregroundStyle(type.tint)
                    .frame(width: 48, height: 48)
                    .background(type.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(component.displayTitle)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Text([component.brand, type.label].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !component.displayCommonName.isEmpty, component.displayCommonName != component.displayTitle {
                Text(component.displayCommonName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Label(component.quantity > 0
                      ? String(localized: "\(component.quantity) in magazzino")
                      : String(localized: "Non disponibile"),
                      systemImage: "shippingbox.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(component.quantity > 0 ? .green : .orange)
                if let storage = component.storageLabel {
                    Label(storage, systemImage: "archivebox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if component.isToOrder {
                    ToOrderBadge()
                }
            }
            HStack(spacing: 8) {
                ComponentCodesRow(component: component)
                SourceBadge(source: component.source)
                if component.needsLCSCForEasyEDA {
                    Text("LCSC per EasyEDA")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .opacity(0.85)
        }
    }

    private var lcscResolutionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 8) {
                Text("Codice LCSC per EasyEDA")
                    .font(.headline)
                if component.isInternalComponentCode {
                    Text("Inventario: \(component.inventoryCode). Per EasyEDA cerca il codice LCSC Cxxxxx — dal MPN o equivalente cinese.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Il componente non ha ancora un codice LCSC Cxxxxx. Cercalo dal MPN per usarlo in EasyEDA.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await lookupChineseEquivalent() }
                    } label: {
                        if isLookingUpEquivalent {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Equivalente cinese", systemImage: "globe.asia.australia")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLookingUpEquivalent || LCSCEquivalentSearchService.keyword(for: component) == nil)

                    if !component.mpn.isEmpty {
                        Button {
                            Task { await lookupLCSCFromMPN() }
                        } label: {
                            if isLookingUpMPN {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Riprova MPN", systemImage: "number")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLookingUpMPN)
                    }
                }
                if LCSCEquivalentSearchService.keyword(for: component) == nil {
                    Text("Aggiungi footprint e valore per abilitare la ricerca equivalenti.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var imageGallery: some View {
        VStack(spacing: 8) {
            let imageURLs = component.imageURLs.filter { RemoteImagePolicy.isAllowed(URL(string: $0)) }
            if imageURLs.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 220, height: 220)
                    .overlay {
                        Image(systemName: component.componentType.icon)
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                TabView(selection: $selectedImageIndex) {
                    ForEach(Array(imageURLs.enumerated()), id: \.offset) { index, urlString in
                        AsyncImage(url: URL(string: urlString)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure:
                                Image(systemName: "photo.badge.exclamationmark")
                            default:
                                ProgressView()
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.automatic)
                .frame(width: 220, height: 220)
            }
        }
    }

    private func storageBinding(_ keyPath: ReferenceWritableKeyPath<Component, String?>) -> Binding<String> {
        Binding(
            get: { component[keyPath: keyPath] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                component[keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
                component.lastUpdated = Date()
            }
        )
    }

    private var inventoryCard: some View {
        GroupBox("Inventario") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Quantità in magazzino") {
                    HStack {
                        Button { adjust(by: -1) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(component.quantity == 0)

                        Text("\(component.quantity)")
                            .font(.title3.monospacedDigit())
                            .frame(minWidth: 48)

                        Button { adjust(by: 1) } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)

                        Stepper("", value: Binding(
                            get: { component.quantity },
                            set: { try? store?.updateQuantity(component, to: $0) }
                        ), in: 0...999_999)
                        .labelsHidden()
                    }
                }

                LabeledContent("Dispensario") {
                    TextField("es. A", text: storageBinding(\.storageLocation))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 180)
                }

                LabeledContent("Numero cassetto") {
                    TextField("es. 12", text: storageBinding(\.storageSlot))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 180)
                }

                LabeledContent("Avviso scorte basse") {
                    Toggle("", isOn: Binding(
                        get: { component.hasLowStockAlertEnabled },
                        set: { enabled in
                            try? store?.setLowStockAlertEnabled(component, enabled: enabled)
                        }
                    ))
                    .labelsHidden()
                }
                .platformHelp("Attiva per ricevere avvisi quando la quantità scende sotto la soglia")

                if component.hasLowStockAlertEnabled {
                    LabeledContent("Soglia minima") {
                        Stepper(value: Binding(
                            get: { component.minQuantity },
                            set: { try? store?.updateMinQuantity(component, to: $0) }
                        ), in: 1...999_999) {
                            Text("\(component.minQuantity)")
                                .monospacedDigit()
                        }
                    }
                }

                if component.isLowStock {
                    Label(
                        component.quantity == 0 ? String(localized: "Esaurito") : String(localized: "Sotto soglia"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(component.quantity == 0 ? .red : .orange)
                } else if component.hasLowStockAlertEnabled {
                    Label("Scorte OK", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if component.isToOrder {
                    Label("Da ordinare — qty 0 in magazzino", systemImage: "cart.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if !component.value.isEmpty && component.value != "N/A" {
                    LabeledContent("Valore", value: component.value)
                }
                if !component.footprint.isEmpty {
                    LabeledContent("Footprint", value: component.footprint)
                }
                if !component.mpn.isEmpty {
                    LabeledContent("MPN", value: component.mpn)
                }
                LabeledContent("Codice CV") {
                    Text(component.inventoryCode)
                        .font(.body.monospaced())
                }
                LabeledContent("LCSC") {
                    Text(component.supplierLCSCCode ?? "—")
                        .font(.body.monospaced())
                        .foregroundStyle(component.supplierLCSCCode == nil ? .tertiary : .primary)
                }
                if let price = component.price, let currency = component.currency {
                    LabeledContent("Prezzo LCSC") {
                        Text(String(format: "%.4f %@", price, currency))
                    }
                }
                if let stock = component.supplierStock {
                    LabeledContent("Stock LCSC", value: "\(stock)")
                }
                LabeledContent("Ultimo aggiornamento") {
                    Text(component.lastUpdated.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 360)
    }

    private var tagsSection: some View {
        GroupBox("Tag & Note") {
            VStack(alignment: .leading, spacing: 10) {
                TagEditor(tags: component.tags) { newTags in
                    try? store?.updateTags(component, tags: newTags)
                }
                TextField("Note personali…", text: Binding(
                    get: { component.notes },
                    set: { try? store?.updateNotes(component, notes: $0) }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            }
        }
    }

    private var stockHistorySection: some View {
        Group {
            if !component.stockMovements.isEmpty {
                GroupBox("Storico movimenti") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(component.stockMovements.sorted(by: { $0.date > $1.date }).prefix(10), id: \.persistentModelID) { movement in
                            HStack {
                                Text(movement.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(movement.delta >= 0 ? "+\(movement.delta)" : "\(movement.delta)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(movement.delta >= 0 ? .green : .red)
                                    .frame(width: 40)
                                Text("→ \(movement.quantityAfter)")
                                    .font(.caption.monospacedDigit())
                                Text(movement.note.isEmpty ? movement.movementReason.label : movement.note)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func adjust(by delta: Int) {
        try? store?.adjustStock(component, delta: delta, reason: .manual)
    }

    private var descriptionSection: some View {
        Group {
            if !component.componentDescription.isEmpty {
                GroupBox("Descrizione") {
                    Text(component.componentDescription)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var parametersSection: some View {
        Group {
            if !component.parameters.isEmpty {
                GroupBox("Parametri tecnici") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(component.parameters.sorted(by: { $0.name < $1.name }), id: \.persistentModelID) { param in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(param.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(param.value)
                                    .font(.body)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.gray.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private var linksSection: some View {
        HStack(spacing: 12) {
            if let datasheet = component.datasheetURL, let url = URL(string: datasheet) {
                Link(destination: url) {
                    Label("Datasheet PDF", systemImage: "doc.richtext")
                }
                .buttonStyle(.bordered)
            }
            if let lcscURL = component.lcscProductURL {
                Link(destination: lcscURL) {
                    Label("Pagina LCSC", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var mpnLookupSheet: some View {
        NavigationStack {
            Group {
                if mpnLookupResults.isEmpty {
                    ContentUnavailableView("Nessun risultato", systemImage: "number")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(mpnLookupResults) { card in
                                CatalogMatchCardView(
                                    card: card,
                                    canAddToProject: false,
                                    onImport: { Task { await importMPNLookupCard(card) } },
                                    onAddToProject: {}
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(mpnLookupTitle.isEmpty ? String(localized: "Risultati LCSC") : mpnLookupTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { showMPNLookup = false }
                }
            }
        }
        .platformSheetFrame(minWidth: 680, minHeight: 480)
    }

    private func lookupLCSCFromMPN() async {
        isLookingUpMPN = true
        defer { isLookingUpMPN = false }
        do {
            let (cards, _) = try await MPNLookupService.search(
                mpn: component.mpn,
                inventory: inventory
            )
            mpnLookupResults = cards
            mpnLookupTitle = String(localized: "LCSC da \(component.mpn)")
            showMPNLookup = true
            if cards.isEmpty {
                infoMessage = String(localized: "\(component.mpn) non è presente nel catalogo LCSC — prova «Equivalente cinese» per alternative con le stesse specifiche.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func lookupChineseEquivalent() async {
        isLookingUpEquivalent = true
        defer { isLookingUpEquivalent = false }
        do {
            let result = try await LCSCEquivalentSearchService.search(
                component: component,
                inventory: inventory
            )
            mpnLookupResults = result.cards
            mpnLookupTitle = String(localized: "Equivalenti LCSC · \(result.keyword)")
            showMPNLookup = true
            if result.cards.isEmpty {
                infoMessage = String(localized: "Nessun equivalente LCSC trovato per «\(result.keyword)». Verifica footprint e valore.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importMPNLookupCard(_ card: CatalogMatchCard) async {
        guard let store else { return }
        let originalID = component.persistentModelID
        do {
            let updated = try await store.applyCatalogMatchToExisting(component, card: card)
            handleReplacement(updated, originalID: originalID)
            showMPNLookup = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enrichFromDigiKey() async {
        guard let store else { return }
        isEnriching = true
        defer { isEnriching = false }
        do {
            if case .chooseCandidate(let candidates) = try await store.enrichFromDigiKey(component) {
                digiKeyCandidates = candidates
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyDigiKeyCandidate(_ candidate: DigiKeyCandidate) async {
        guard let store else { return }
        isEnriching = true
        defer { isEnriching = false }
        do {
            try await store.applyDigiKeyRecord(candidate.record, to: component)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enrich(source: DataSource) async {
        guard let store else { return }
        isEnriching = true
        defer { isEnriching = false }
        let originalID = component.persistentModelID
        do {
            if source == .lcsc {
                let updated = try await store.enrichFromLCSC(component)
                handleReplacement(updated, originalID: originalID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Component {
    var lcscProductURL: URL? {
        guard let code = supplierLCSCCode else { return nil }
        return URL(string: "https://www.lcsc.com/product-detail/\(code).html")
    }
}

struct SourceBadge: View {
    let source: DataSource

    var body: some View {
        Text(source.label.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch source {
        case .manual: .gray
        case .lcsc: .orange
        case .digikey: .red
        case .dual: .purple
        }
    }
}

struct ComponentThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, RemoteImagePolicy.isAllowed(url) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.12)
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
        }
    }
}

struct ToOrderBadge: View {
    var body: some View {
        Text("DA ORDINARE")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.2))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
    }
}

struct ComponentDetailSheet: View {
    @Bindable var component: Component
    var store: ComponentStore?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ComponentDetailView(component: component, store: store)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Chiudi") { dismiss() }
                    }
                }
        }
        .platformSheetFrame(minWidth: 720, minHeight: 600)
    }
}
