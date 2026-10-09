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
    @State private var mouserKey = ""
    @State private var mouserSaved = MouserKeychain.isConfigured
    @State private var nexar = NexarKeychain.load() ?? NexarCredentials()
    @State private var nexarSaved = NexarKeychain.isConfigured
    @State private var shareKeys = SupplierKeychain.sharesAcrossDevices

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
            refreshSupplierStatus()
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
            Picker("Fornitore predefinito", selection: $config.catalog.searchProvider) {
                ForEach(CatalogSearchProvider.available) { provider in
                    Text(provider.label).tag(provider)
                }
            }
        } header: {
            Text("Ricerca")
        } footer: {
            Text("\(config.catalog.searchProvider.detail) Gli altri distributori configurati si interrogano a richiesta con «Cerca anche su…».")
        }
    }

    // MARK: DigiKey (facoltativo)

    private var digiKeySection: some View {
        Section {
            Toggle(isOn: Binding(get: { shareKeys }, set: { setShareKeys($0) })) {
                Text("Condividi con i miei dispositivi")
                Text("Portachiavi iCloud: le stesse chiavi su Mac e iPad")
            }
            DisclosureGroup {
                SecureField(mouserSaved ? String(localized: "Chiave salvata — inseriscine una nuova per sostituirla") : String(localized: "Search API key"), text: $mouserKey)
                    .textContentType(.password)
                HStack {
                    Button("Salva sul dispositivo") { saveMouser() }
                        .disabled(mouserKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if mouserSaved {
                        Spacer()
                        Button("Elimina", role: .destructive) {
                            MouserKeychain.delete()
                            mouserSaved = false
                        }
                    }
                }
                Link("Richiedi una chiave gratuita su mouser.com", destination: URL(string: "https://www.mouser.com/api-hub/")!)
                    .font(.caption)
            } label: {
                LabeledContent("Mouser") {
                    Text(mouserSaved ? "Configurato" : "Non usato")
                        .foregroundStyle(mouserSaved ? .green : .secondary)
                }
            }
            DisclosureGroup {
                TextField("Client ID", text: $nexar.clientID)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $nexar.clientSecret)
                    .textContentType(.password)
                LabeledContent("Paese · valuta") {
                    HStack {
                        TextField("IT", text: $nexar.country).frame(maxWidth: 50)
                        TextField("EUR", text: $nexar.currency).frame(maxWidth: 60)
                    }
                    .multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Salva sul dispositivo") { saveNexar() }
                        .disabled(!nexar.isComplete)
                    if nexarSaved {
                        Spacer()
                        Button("Elimina", role: .destructive) {
                            NexarKeychain.delete()
                            nexar = NexarCredentials()
                            nexarSaved = false
                        }
                    }
                }
                Link("Crea un'app gratuita su nexar.com", destination: URL(string: "https://nexar.com/api")!)
                    .font(.caption)
            } label: {
                LabeledContent("Nexar (Octopart)") {
                    Text(nexarSaved ? "Configurato" : "Non usato")
                        .foregroundStyle(nexarSaved ? .green : .secondary)
                }
            }
            DisclosureGroup {
                TextField("Client ID", text: $digiKey.clientID)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $digiKey.clientSecret)
                    .textContentType(.password)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Facoltativo: prezzi, disponibilità e ricerca dai distributori con API ufficiale. Chiavi e token li inserisci tu (anche scegliendoli dalle Password salvate); non vanno nella cartella né altrove e servono solo per le richieste ad api.mouser.com, api.digikey.com e api.nexar.com.")
                Text(shareKeys
                     ? "Le chiavi sono nel Portachiavi iCloud, cifrato end-to-end: le vede solo ComponentVault sui dispositivi con il tuo Apple Account. Disattivando, restano solo qui e spariscono dagli altri dispositivi."
                     : "Le chiavi restano nel Portachiavi di questo dispositivo: su ogni Mac o iPad vanno inserite una volta.")
            }
        }
    }

    private func saveDigiKey() {
        do {
            try DigiKeyKeychain.save(digiKey)
            digiKeySaved = true
            digiKeyMessage = shareKeys
                ? String(localized: "Salvate nel Portachiavi iCloud.")
                : String(localized: "Salvate nel Portachiavi di questo dispositivo.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveNexar() {
        do {
            var credentials = nexar
            credentials.accessToken = ""
            credentials.expiresAt = nil
            try NexarKeychain.save(credentials)
            nexarSaved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveMouser() {
        do {
            try MouserKeychain.save(mouserKey)
            mouserKey = ""
            mouserSaved = true
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

    private func setShareKeys(_ shared: Bool) {
        do {
            try SupplierKeychain.setSharesAcrossDevices(shared)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshSupplierStatus()
    }

    private func refreshSupplierStatus() {
        shareKeys = SupplierKeychain.sharesAcrossDevices
        mouserSaved = MouserKeychain.isConfigured
        nexarSaved = NexarKeychain.isConfigured
        digiKeySaved = DigiKeyKeychain.isConfigured
        if digiKeySaved, digiKey.clientID.isEmpty { digiKey = DigiKeyKeychain.load() ?? digiKey }
        if nexarSaved, nexar.clientID.isEmpty { nexar = NexarKeychain.load() ?? nexar }
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
