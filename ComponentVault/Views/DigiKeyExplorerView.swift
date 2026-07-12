import SwiftUI
import SwiftData

enum DigiKeyExplorerMode: String, CaseIterable, Identifiable {
    case keyword
    case barcode
    case crossRef

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keyword: "Keyword"
        case .barcode: "Barcode"
        case .crossRef: "Sostituti"
        }
    }
}

struct DigiKeyExplorerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DigiKeyExplorerMode = .keyword
    @State private var keyword = ""
    @State private var barcode = ""
    @State private var crossRefPN = ""
    @State private var candidates: [DigiKeyCandidate] = []
    @State private var substitutions: [DigiKeyCrossReference] = []
    @State private var alternates: [DigiKeyAlternatePackage] = []
    @State private var selectedCandidateID: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var store: ComponentStore?
    @State private var importedComponent: Component?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .platformSheetFrame(minWidth: 760, minHeight: 560)
        .navigationTitle("Esplora DigiKey")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Chiudi") { dismiss() }
            }
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .sheet(item: $importedComponent) { component in
            ComponentDetailSheet(component: component, store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Modalità", selection: $mode) {
                ForEach(DigiKeyExplorerMode.allCases) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .keyword:
                HStack {
                    TextField("MPN, keyword, manufacturer…", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                    Button("Cerca") { Task { await searchKeyword() } }
                        .disabled(isLoading || keyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .barcode:
                HStack {
                    TextField("Codice a barre prodotto", text: $barcode)
                        .textFieldStyle(.roundedBorder)
                    Button("Lookup") { Task { await searchBarcode() } }
                        .disabled(isLoading || barcode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .crossRef:
                HStack {
                    TextField("DigiKey PN o MPN per sostituti", text: $crossRefPN)
                        .textFieldStyle(.roundedBorder)
                    Button("Sostituti") { Task { await loadSubstitutions() } }
                        .disabled(isLoading || crossRefPN.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if isLoading { ProgressView().controlSize(.small) }
            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .keyword, .barcode:
            candidateList
        case .crossRef:
            crossRefList
        }
    }

    private var candidateList: some View {
        Group {
            if candidates.isEmpty && !isLoading {
                ContentUnavailableView("Nessun risultato", systemImage: "magnifyingglass")
            } else {
                List(candidates, selection: $selectedCandidateID) { candidate in
                    DigiKeyExplorerRow(candidate: candidate) {
                        Task { await importCandidate(candidate) }
                    } onDetails: {
                        Task { await loadAlternates(for: candidate) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !alternates.isEmpty,
               let selectedID = selectedCandidateID,
               let selected = candidates.first(where: { $0.id == selectedID }) {
                alternateBar(for: selected)
            }
        }
    }

    private var crossRefList: some View {
        Group {
            if substitutions.isEmpty && !isLoading {
                ContentUnavailableView("Cross-reference", systemImage: "arrow.triangle.swap")
            } else {
                List(substitutions) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.digikeyPartNumber.isEmpty ? item.mpn : item.digikeyPartNumber)
                            .font(.headline.monospaced())
                        Text(item.description).font(.caption).lineLimit(2)
                        if let stock = item.stock {
                            Text("Stock \(stock)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func alternateBar(for candidate: DigiKeyCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Packaging alternativo — \(candidate.digikeyPartNumber)")
                .font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(alternates) { alt in
                        Text("\(alt.digikeyPartNumber) · \(alt.packaging)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.4))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func searchKeyword() async {
        guard let provider = DigiKeyProvider.configured() else {
            errorMessage = "DigiKey non configurato."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            candidates = try await provider.searchCatalog(keyword: keyword, recordCount: 10)
            statusMessage = "\(candidates.count) risultati"
            alternates = []
        } catch {
            errorMessage = error.localizedDescription
            candidates = []
        }
    }

    private func searchBarcode() async {
        guard let provider = DigiKeyProvider.configured() else {
            errorMessage = "DigiKey non configurato."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            candidates = try await provider.searchBarcode(barcode)
            statusMessage = "\(candidates.count) da barcode"
            alternates = []
        } catch {
            errorMessage = error.localizedDescription
            candidates = []
        }
    }

    private func loadSubstitutions() async {
        guard let provider = DigiKeyProvider.configured() else {
            errorMessage = "DigiKey non configurato."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            substitutions = try await provider.fetchSubstitutions(
                partNumber: crossRefPN,
                referenceMPN: crossRefPN
            )
            statusMessage = "\(substitutions.count) sostituti"
        } catch {
            errorMessage = error.localizedDescription
            substitutions = []
        }
    }

    private func loadAlternates(for candidate: DigiKeyCandidate) async {
        guard let provider = DigiKeyProvider.configured() else { return }
        selectedCandidateID = candidate.id
        do {
            alternates = try await provider.fetchAlternatePackaging(
                partNumber: candidate.digikeyPartNumber
            )
        } catch {
            errorMessage = error.localizedDescription
            alternates = []
        }
    }

    private func importCandidate(_ candidate: DigiKeyCandidate) async {
        guard let store else { return }
        do {
            let component = try await store.importDigiKeyCandidate(candidate)
            importedComponent = component
            statusMessage = component.isToOrder
                ? "Scheda salvata — da ordinare"
                : "Aggiornato \(component.lcscCode)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DigiKeyExplorerRow: View {
    let candidate: DigiKeyCandidate
    let onImport: () -> Void
    let onDetails: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.digikeyPartNumber)
                    .font(.headline.monospaced())
                Text(candidate.mpn)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !candidate.description.isEmpty {
                    Text(candidate.description)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let price = candidate.unitPrice, let currency = candidate.currency {
                Text(String(format: "%.3f %@", price, currency))
                    .font(.caption.monospacedDigit())
            }
            Button("Pack", action: onDetails)
                .buttonStyle(.borderless)
            Button("Importa", action: onImport)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
