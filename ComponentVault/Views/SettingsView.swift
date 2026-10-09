import SwiftUI
import SwiftData

/// Impostazioni: una cartella per tutto, la libreria KiCad (dal Mac), scambio dati e ricerca.
/// Ogni modifica si salva da sola nel file di configurazione.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var components: [Component]

    @State private var config = AppConfigIO.current()
    @State private var folderPath = SharedFolder.displayPath
    @State private var folderReachable = SharedFolder.isReachable
    @State private var worker: KiCadWorkerStatus?
    @State private var showFolderPicker = false
    @State private var showKiCadPicker = false
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var errorMessage: String?
    @State private var digiKey = DigiKeyKeychain.load() ?? DigiKeyCredentials()
    @State private var digiKeySaved = DigiKeyKeychain.isConfigured
    @State private var digiKeyMessage: String?

    private var hasFolder: Bool { !folderPath.isEmpty }

    var body: some View {
        Form {
            folderSection
            kicadSection
            syncSection
            searchSection
            digiKeySection
        }
        .formStyle(.grouped)
        .navigationTitle("Impostazioni")
        .onAppear {
            config = AppConfigIO.reload()
            refreshFolderStatus()
        }
        .task { worker = await KiCadQueue.workerStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .sharedFolderChanged)) { _ in
            refreshFolderStatus()
        }
        .onChange(of: config) { _, newValue in
            do {
                try AppConfigIO.save(newValue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Errore", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Cartella

    private var folderSection: some View {
        Section {
            if hasFolder {
                LabeledContent {
                    Text(folderReachable ? "Raggiungibile" : "Non raggiungibile")
                        .foregroundStyle(folderReachable ? .green : .orange)
                } label: {
                    Label {
                        Text(folderPath)
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: folderReachable ? "folder.fill" : "folder.badge.questionmark")
                    }
                }
            }
            HStack {
                Button(hasFolder ? "Cambia cartella…" : "Scegli cartella…") {
                    showFolderPicker = true
                }
                .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
                    chooseFolder(result)
                }
                if hasFolder {
                    Spacer()
                    Button("Scollega", role: .destructive) { disconnectFolder() }
                }
            }
        } header: {
            Text("Cartella")
        } footer: {
            Text(hasFolder
                 ? "Qui stanno la configurazione, i dati da scambiare e le richieste per KiCad. Scegli la stessa cartella su tutti i tuoi dispositivi."
                 : "Scegli una cartella che vedono tutti i tuoi dispositivi, ad esempio in iCloud Drive. Senza cartella tutto resta su questo dispositivo.")
        }
    }

    // MARK: KiCad

    private var kicadSection: some View {
        Section {
            #if os(macOS)
            LabeledContent("Libreria") {
                HStack {
                    Text(config.kicad.libraryPath.isEmpty ? String(localized: "Non impostata") : config.kicad.libraryPath)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Scegli…") { showKiCadPicker = true }
                        .fileImporter(isPresented: $showKiCadPicker, allowedContentTypes: [.folder]) { result in
                            if let url = try? result.get() { config.kicad.libraryPath = url.path }
                        }
                }
            }
            #else
            LabeledContent("Libreria") {
                Text(config.kicad.libraryPath.isEmpty
                     ? String(localized: "Si imposta dal Mac")
                     : config.kicad.libraryName)
                    .foregroundStyle(.secondary)
            }
            #endif
            LabeledContent("Mac con KiCad") {
                if let worker {
                    Text(worker.isActive
                         ? String(localized: "Attivo (\(worker.host))")
                         : String(localized: "Non attivo (\(worker.host))"))
                        .foregroundStyle(worker.isActive ? .green : .secondary)
                } else {
                    Text("Mai visto").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("KiCad")
        } footer: {
            #if os(macOS)
            Text("La cartella della tua libreria KiCad. Il percorso va nel file di configurazione, così gli altri dispositivi sanno quale libreria usa questo Mac.")
            #else
            Text("La libreria KiCad si sceglie dall'app su Mac; l'iPad la legge dal file di configurazione nella cartella.")
            #endif
        }
    }

    // MARK: Scambio dati

    private var syncSection: some View {
        Section {
            HStack {
                Button("Sincronizza ora") {
                    Task { await syncNow() }
                }
                .disabled(isSyncing || !hasFolder)
                if isSyncing {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            Toggle("All'avvio dell'app", isOn: $config.sync.autoOnLaunch)
                .disabled(!hasFolder)
            Picker("Ogni", selection: $config.sync.intervalMinutes) {
                Text("Disattivato").tag(0)
                Text("15 minuti").tag(15)
                Text("30 minuti").tag(30)
                Text("60 minuti").tag(60)
            }
            .disabled(!hasFolder)
            if let syncMessage {
                Text(syncMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Scambio dati")
        } footer: {
            if config.sync.lastSyncAt.isEmpty {
                Text("Inventario e progetti si fondono con quelli degli altri dispositivi: vince la modifica più recente. Locale: \(components.count) componenti.")
            } else {
                Text("Ultimo scambio: \(SyncDateParser.parse(config.sync.lastSyncAt).formatted(date: .abbreviated, time: .shortened)) · Locale: \(components.count) componenti.")
            }
        }
    }

    // MARK: Ricerca

    private var searchSection: some View {
        Section {
            Picker("Catalogo", selection: $config.catalog.searchProvider) {
                ForEach(CatalogSearchProvider.allCases) { provider in
                    Text(provider.label).tag(provider)
                }
            }
            LabeledContent("Pausa tra richieste LCSC") {
                Stepper(value: $config.lcsc.requestDelayMs, in: 200...3000, step: 100) {
                    Text("\(config.lcsc.requestDelayMs) ms").monospacedDigit()
                }
            }
        } header: {
            Text("Ricerca")
        } footer: {
            Text(config.catalog.searchProvider.detail)
        }
    }

    // MARK: DigiKey (facoltativo)

    private var digiKeySection: some View {
        Section {
            DisclosureGroup {
                TextField("Client ID", text: $digiKey.clientID)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $digiKey.clientSecret)
                SecureField("Access token", text: $digiKey.accessToken)
                SecureField("Refresh token", text: $digiKey.refreshToken)
                Picker("Ambiente", selection: $digiKey.environment) {
                    Text("Production").tag(DigiKeyCredentials.Environment.production)
                    Text("Sandbox").tag(DigiKeyCredentials.Environment.sandbox)
                }
                LabeledContent("Mercato · valuta") {
                    HStack {
                        TextField("IT", text: $digiKey.market).frame(maxWidth: 50)
                        TextField("EUR", text: $digiKey.currency).frame(maxWidth: 60)
                    }
                    .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Salva sul dispositivo") { saveDigiKey() }
                        .disabled(!digiKey.isComplete)
                    if digiKeySaved {
                        Spacer()
                        Button("Elimina", role: .destructive) { deleteDigiKey() }
                    }
                }
                if let digiKeyMessage {
                    Text(digiKeyMessage).font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                LabeledContent("DigiKey") {
                    Text(digiKeySaved ? "Configurato" : "Non usato")
                        .foregroundStyle(digiKeySaved ? .green : .secondary)
                }
            }
        } header: {
            Text("Fornitori")
        } footer: {
            Text("Facoltativo. Le credenziali e i token DigiKey li inserisci tu; restano nel Portachiavi di questo dispositivo, non vanno nella cartella né altrove e servono solo per le richieste ad api.digikey.com.")
        }
    }

    private func saveDigiKey() {
        do {
            try DigiKeyKeychain.save(digiKey)
            digiKeySaved = true
            digiKeyMessage = String(localized: "Salvate nel Portachiavi di questo dispositivo.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteDigiKey() {
        DigiKeyKeychain.delete()
        digiKey = DigiKeyCredentials()
        digiKeySaved = false
        digiKeyMessage = String(localized: "Credenziali DigiKey eliminate.")
    }

    // MARK: Azioni

    private func refreshFolderStatus() {
        folderPath = SharedFolder.displayPath
        folderReachable = SharedFolder.isReachable
    }

    private func chooseFolder(_ result: Result<URL, Error>) {
        do {
            let previous = AppConfigIO.current()
            try SharedFolder.set(result.get())
            // Se un altro dispositivo ha già una configurazione nella cartella, si usa quella.
            try AppConfigIO.adoptFolder(carrying: previous)
            config = AppConfigIO.current()
            refreshFolderStatus()
            Task {
                worker = await KiCadQueue.workerStatus()
                await KiCadLibraryStore.shared.refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnectFolder() {
        // La configurazione in uso resta su questo dispositivo.
        let previous = AppConfigIO.current()
        SharedFolder.clear()
        do {
            try AppConfigIO.save(previous)
        } catch {
            errorMessage = error.localizedDescription
        }
        config = AppConfigIO.current()
        worker = nil
        refreshFolderStatus()
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            syncMessage = try await FolderSync.run(modelContext: modelContext)
            config.sync.lastSyncAt = AppConfigIO.current().sync.lastSyncAt
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: Component.self, inMemory: true)
}
