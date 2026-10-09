import SwiftUI
import SwiftData
#if os(iOS)
import VisionKit
#endif

/// Carico in magazzino da etichetta: inquadra il QR LCSC o il DataMatrix
/// di un distributore (o usa un lettore USB), indica dispensario e numero, carica.
/// Pensato per caricare un ordine intero di seguito: il dispensario resta impostato.
struct ScanImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var store: ComponentStore?
    @State private var label: ScannedLabel?
    @State private var existing: Component?
    @State private var quantity = 1
    @AppStorage("ComponentVault.scan.lastLocation") private var location = ""
    @State private var slot = ""
    @State private var manualCode = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var loaded: [LoadedEntry] = []
    @State private var knownLocations: [String] = []
    @FocusState private var manualFieldFocused: Bool

    private struct LoadedEntry: Identifiable {
        let id = UUID()
        let title: String
        let quantity: Int
        let place: String?
        let created: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                scannerSection
                if let label {
                    labelSection(label)
                    placementSection
                    Section {
                        Button {
                            Task { await save(label) }
                        } label: {
                            HStack {
                                Spacer()
                                if isSaving {
                                    ProgressView()
                                } else {
                                    Label(existing == nil ? String(localized: "Aggiungi all'inventario") : String(localized: "Carica in magazzino"),
                                          systemImage: "tray.and.arrow.down.fill")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .listRowBackground(Color.clear)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if !loaded.isEmpty {
                    loadedSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Carica da etichetta")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .onAppear {
                if store == nil { store = ComponentStore(modelContext: modelContext) }
                knownLocations = store?.knownStorageLocations() ?? []
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: Sezioni

    @ViewBuilder
    private var scannerSection: some View {
        Section {
            #if os(iOS)
            if LabelScannerView.isSupported {
                LabelScannerView { payload in
                    handle(payload)
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .listRowInsets(EdgeInsets())
                .accessibilityLabel("Fotocamera: inquadra l'etichetta")
            } else {
                Label("Fotocamera non disponibile su questo dispositivo: usa il campo qui sotto.", systemImage: "camera.badge.ellipsis")
                    .foregroundStyle(.secondary)
            }
            #endif
            HStack {
                TextField("Codice LCSC, MPN o lettura del lettore USB", text: $manualCode)
                    .focused($manualFieldFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .onSubmit { submitManual() }
                Button("Usa") { submitManual() }
                    .disabled(manualCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Text("Riconosce il QR delle buste LCSC/JLCPCB, il DataMatrix dei distributori (MPN e quantità) e i codici LCSC (C…).")
        }
    }

    private func labelSection(_ label: ScannedLabel) -> some View {
        Section {
            if let mpn = label.mpn { LabeledContent("MPN", value: mpn).textSelection(.enabled) }
            if let lcsc = label.lcsc { LabeledContent("LCSC", value: lcsc).textSelection(.enabled) }
            if let manufacturer = label.manufacturer { LabeledContent("Produttore", value: manufacturer) }
            if let existing {
                Label {
                    if let place = existing.storageLabel {
                        Text("Già in inventario: \(existing.quantity) pz · \(place)")
                    } else {
                        Text("Già in inventario: \(existing.quantity) pz")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label("Nuovo componente: i dati vengono presi da LCSC se disponibili.", systemImage: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(kindTitle(label.kind))
        }
    }

    private var placementSection: some View {
        Section("Quantità e posizione") {
            Stepper(value: $quantity, in: 0...1_000_000) {
                HStack {
                    Text("Quantità")
                    Spacer()
                    TextField("Quantità", value: $quantity, format: .number)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .frame(maxWidth: 110)
                }
            }
            HStack {
                TextField("Dispensario", text: $location)
                if !knownLocations.isEmpty {
                    Menu {
                        ForEach(knownLocations, id: \.self) { name in
                            Button(name) { location = name }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .accessibilityLabel("Dispensari già usati")
                }
            }
            TextField("Numero cassetto", text: $slot)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
    }

    private var loadedSection: some View {
        Section("Caricati in questa sessione") {
            ForEach(loaded) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.body.monospaced())
                        if let place = entry.place {
                            Text(place).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("+\(entry.quantity)")
                        .monospacedDigit()
                        .foregroundStyle(.green)
                    if entry.created {
                        Text("nuovo")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Azioni

    private func kindTitle(_ kind: ScannedLabel.Kind) -> String {
        switch kind {
        case .lcsc: String(localized: "Etichetta LCSC")
        case .ecia: String(localized: "Etichetta distributore")
        case .text: String(localized: "Codice")
        }
    }

    private func submitManual() {
        let text = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if LabelParser.parse(text) != nil {
            handle(text)
        } else {
            // Né etichetta né codice LCSC: lo si tratta come MPN digitato.
            apply(ScannedLabel(kind: .text, mpn: text, raw: text))
        }
        manualCode = ""
    }

    private func handle(_ payload: String) {
        guard let parsed = LabelParser.parse(payload), parsed != label, !isSaving else { return }
        apply(parsed)
    }

    private func apply(_ parsed: ScannedLabel) {
        label = parsed
        existing = store?.existingComponent(for: parsed)
        quantity = parsed.quantity ?? 1
        slot = existing?.storageSlot ?? ""
        if let existingLocation = existing?.storageLocation, !existingLocation.isEmpty {
            location = existingLocation
        }
        errorMessage = nil
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    private func save(_ label: ScannedLabel) async {
        guard let store else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let result = try await store.receiveScanned(label, quantity: quantity, location: location, slot: slot)
            loaded.insert(
                LoadedEntry(
                    title: result.component.displayTitle,
                    quantity: quantity,
                    place: result.component.storageLabel,
                    created: result.created
                ),
                at: 0
            )
            knownLocations = store.knownStorageLocations()
            self.label = nil
            existing = nil
            slot = ""
            errorMessage = nil
            manualFieldFocused = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if os(iOS)
/// Fotocamera live con VisionKit: codici a barre (QR, DataMatrix, Code 128…).
struct LabelScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    @MainActor static var isSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning { try? controller.startScanning() }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onPayload(payload)
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                onPayload(payload)
            }
        }
    }
}
#endif
