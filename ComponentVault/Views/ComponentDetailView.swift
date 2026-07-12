import SwiftUI
import SwiftData

struct ComponentDetailView: View {
    @Bindable var component: Component
    var store: ComponentStore?
    var onReplaced: ((Component) -> Void)? = nil

    @Query(sort: \Component.lcscCode) private var inventory: [Component]

    @State private var selectedImageIndex = 0
    @State private var isEnriching = false
    @State private var errorMessage: String?
    @State private var digiKeyPicker: DigiKeyCandidatePicker?
    @State private var mpnLookupResults: [CatalogMatchCard] = []
    @State private var showMPNLookup = false
    @State private var mpnLookupTitle = ""
    @State private var isLookingUpMPN = false
    @State private var isLookingUpEquivalent = false
    @State private var infoMessage: String?

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
                descriptionSection
                supplierComparisonSection
                digikeyCommercialSection
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
                    Task { await enrichBoth() }
                } label: {
                    Label("Entrambi", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isEnriching || store == nil)

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

                Button {
                    Task { await enrich(source: .digikey) }
                } label: {
                    Label("DigiKey", systemImage: "dollarsign.circle")
                }
                .disabled(isEnriching || store == nil || component.mpn.isEmpty)
                .platformHelp(component.mpn.isEmpty ? "Serve un MPN" : "Arricchisci da DigiKey (richiede token in Impostazioni)")

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

                if let digiKeyURL = component.digikeyProductURL {
                    Link(destination: digiKeyURL) {
                        Label("Apri su DigiKey", systemImage: "cart")
                    }
                }
            }
        }
        .sheet(item: $digiKeyPicker) { picker in
            DigiKeyCandidateSheet(
                candidates: picker.candidates,
                onSelect: { candidate in
                    digiKeyPicker = nil
                    Task { await applyDigiKeyCandidate(candidate) }
                },
                onCancel: { digiKeyPicker = nil }
            )
        }
        .sheet(isPresented: $showMPNLookup) {
            mpnLookupSheet
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
            infoMessage = "Codice LCSC assegnato: \(updated.supplierLCSCCode ?? updated.lcscCode)"
        } else if updated.supplierLCSCCode != component.supplierLCSCCode {
            onReplaced?(updated)
            infoMessage = "Codice LCSC assegnato: \(updated.supplierLCSCCode ?? updated.lcscCode)"
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
                Text("Non presente in magazzino. La scheda è salvata per riferimento; lo stock DigiKey/LCSC è del fornitore, non del tuo inventario.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ComponentCodesRow(component: component)
                SourceBadge(source: component.source)
                if component.isToOrder {
                    ToOrderBadge()
                }
                if component.isInternalComponentCode {
                    Text("CV interno")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                } else if component.needsLCSCForEasyEDA {
                    Text("LCSC per EasyEDA")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if !component.displayCommonName.isEmpty {
                Text(component.displayCommonName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !component.mpn.isEmpty {
                Text(component.mpn)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            if !component.brand.isEmpty {
                Text(component.brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !component.category.isEmpty {
                Text(component.category)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
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
                    Text("Aggiungi footprint e valore (o arricchisci da DigiKey) per abilitare la ricerca equivalenti.")
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
            if component.imageURLs.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 220, height: 220)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                TabView(selection: $selectedImageIndex) {
                    ForEach(Array(component.imageURLs.enumerated()), id: \.offset) { index, urlString in
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

                LabeledContent("Soglia minima") {
                    Stepper(value: Binding(
                        get: { component.minQuantity },
                        set: { try? store?.updateMinQuantity(component, to: $0) }
                    ), in: 0...999_999) {
                        Text("\(component.minQuantity)")
                            .monospacedDigit()
                    }
                }

                if component.isLowStock {
                    Label(
                        component.quantity == 0 ? "Esaurito" : "Sotto soglia",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(component.quantity == 0 ? .red : .orange)
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
                if let dkpn = component.digikeyPartNumber, !dkpn.isEmpty {
                    LabeledContent("DigiKey P/N", value: dkpn)
                } else {
                    LabeledContent("DigiKey P/N") {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                if let price = component.price, let currency = component.currency {
                    LabeledContent(component.source == .digikey ? "Prezzo DigiKey" : "Prezzo LCSC") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.4f %@", price, currency))
                            if component.source == .digikey,
                               let qtyPrice = component.digikeyUnitPriceForInventory,
                               component.quantity > 0,
                               abs(qtyPrice - price) > 0.0001 {
                                Text("a qty \(component.quantity): \(String(format: "%.4f", qtyPrice)) \(currency)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let stock = component.supplierStock {
                    LabeledContent(
                        component.source == .digikey ? "Stock DigiKey" : "Stock LCSC",
                        value: "\(stock)"
                    )
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

    private var supplierComparisonSection: some View {
        Group {
            if component.hasLCSCSnapshot || component.hasDigiKeySnapshot {
                SupplierComparisonView(component: component)
            }
        }
    }

    private var digikeyCommercialSection: some View {
        Group {
            if component.hasDigiKeySnapshot, let snapshot = component.digikeySnapshot, !snapshot.priceBreaks.isEmpty {
                GroupBox("DigiKey — dati commerciali") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let moq = component.minimumOrderQuantity, moq > 1 {
                            LabeledContent("MOQ", value: "\(moq)")
                        }
                        if let weeks = component.leadTimeWeeks {
                            LabeledContent("Lead time", value: "\(weeks) settimane")
                        }
                        if let status = component.digikeyProductStatus, !status.isEmpty {
                            LabeledContent("Stato prodotto", value: status)
                        }
                        if let fetched = component.digikeyLastFetched {
                            LabeledContent("Prezzi aggiornati") {
                                Text(fetched.formatted(date: .abbreviated, time: .shortened))
                            }
                        }

                        if !component.priceBreaks.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Scaglioni prezzo")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)

                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                    GridRow {
                                        Text("Qty").font(.caption.weight(.semibold))
                                        Text("Unitario").font(.caption.weight(.semibold))
                                        Text("Totale").font(.caption.weight(.semibold))
                                    }
                                    ForEach(component.priceBreaks) { tier in
                                        let highlight = component.quantity >= tier.quantity
                                        GridRow {
                                            Text("\(tier.quantity)+")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(highlight ? .primary : .secondary)
                                            Text(String(format: "%.4f", tier.unitPrice))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(highlight ? .green : .secondary)
                                            Text(tier.totalPrice.map { String(format: "%.2f", $0) } ?? "—")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 2)
                                        .background(highlight ? Color.green.opacity(0.08) : Color.clear)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
            if let digiKeyURL = component.digikeyProductURL {
                Link(destination: digiKeyURL) {
                    Label("Pagina DigiKey", systemImage: "cart")
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
            .navigationTitle(mpnLookupTitle.isEmpty ? "Risultati LCSC" : mpnLookupTitle)
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
            mpnLookupTitle = "LCSC da \(component.mpn)"
            showMPNLookup = true
            if cards.isEmpty {
                infoMessage = "\(component.mpn) non è presente nel catalogo LCSC — prova «Equivalente cinese» per alternative con le stesse specifiche."
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
            mpnLookupTitle = "Equivalenti LCSC · \(result.keyword)"
            showMPNLookup = true
            if result.cards.isEmpty {
                infoMessage = "Nessun equivalente LCSC trovato per «\(result.keyword)». Verifica footprint e valore, o ordina solo da DigiKey."
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

    private func enrichBoth() async {
        guard let store else { return }
        isEnriching = true
        defer { isEnriching = false }
        let originalID = component.persistentModelID
        do {
            switch try await store.enrichFromBoth(component) {
            case .applied:
                if let focus = store.focusComponent {
                    handleReplacement(focus, originalID: originalID)
                    store.focusComponent = nil
                }
            case .chooseCandidate(let candidates):
                digiKeyPicker = DigiKeyCandidatePicker(candidates: candidates)
            }
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
            switch source {
            case .lcsc:
                let updated = try await store.enrichFromLCSC(component)
                handleReplacement(updated, originalID: originalID)
            case .digikey:
                switch try await store.enrichFromDigiKey(component) {
                case .applied:
                    if let focus = store.focusComponent {
                        handleReplacement(focus, originalID: originalID)
                        store.focusComponent = nil
                    }
                case .chooseCandidate(let candidates):
                    digiKeyPicker = DigiKeyCandidatePicker(candidates: candidates)
                }
            case .dual:
                switch try await store.enrichFromBoth(component) {
                case .applied:
                    if let focus = store.focusComponent {
                        handleReplacement(focus, originalID: originalID)
                        store.focusComponent = nil
                    }
                case .chooseCandidate(let candidates):
                    digiKeyPicker = DigiKeyCandidatePicker(candidates: candidates)
                }
            case .manual:
                break
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
}

struct DigiKeyCandidatePicker: Identifiable {
    let id = UUID()
    let candidates: [DigiKeyCandidate]
}

extension Component {
    var digikeyProductURL: URL? {
        guard let urlString = digikeySnapshot?.productURL ?? supplierProductURL,
              !urlString.isEmpty,
              let url = URL(string: urlString) else {
            return nil
        }
        return url
    }

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
            if let url {
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
