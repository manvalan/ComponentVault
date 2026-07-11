import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @AppStorage("defaultCSVPath") private var defaultCSVPath = "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
    @AppStorage("lcscRequestDelayMs") private var lcscRequestDelayMs = 800.0
    @AppStorage("apiBaseURL") private var apiBaseURL = "https://cvault.michelebigi.it"
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("lastSyncAt") private var lastSyncAt = ""
    @AppStorage("lastRemoteCount") private var lastRemoteCount = -1
    @AppStorage("autoSyncOnLaunch") private var autoSyncOnLaunch = false
    @AppStorage("autoSyncIntervalMinutes") private var autoSyncIntervalMinutes = 0

    @State private var store: ComponentStore?
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showPullConfirm = false

    private var digiKeyConfigured: Bool { DigiKeyConfig.load() != nil }
    private var digiKeyTokenExists: Bool {
        FileManager.default.fileExists(atPath: "/Users/michelebigi/LCSC/digikey_token_cache.json")
    }

    private var serverConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                syncSection
                autoSyncSection
                pathsSection
                lcscSection
                digiKeySection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Impostazioni")
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
        }
        .alert("Scaricare dal server?", isPresented: $showPullConfirm) {
            Button("Annulla", role: .cancel) {}
            Button("Scarica", role: .destructive) {
                Task { await pullFromServer() }
            }
        } message: {
            Text("I dati locali verranno sovrascritti con l'inventario sul server remoto.")
        }
        .alert("Errore", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var serverSection: some View {
        GroupBox("Server remoto") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("URL API") {
                    TextField("https://cvault.michelebigi.it", text: $apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API key") {
                    SecureField("Chiave segreta", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    statusPill(
                        label: serverConfigured ? "Configurato" : "Incompleto",
                        ok: serverConfigured
                    )
                    if lastRemoteCount >= 0 {
                        Text("Server: \(lastRemoteCount) componenti")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Locale: \(components.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Solo chi ha la API key può leggere o modificare l'inventario.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var syncSection: some View {
        GroupBox("Sincronizzazione") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Verifica connessione") {
                        Task { await testConnection() }
                    }
                    .disabled(isBusy || !serverConfigured)

                    Button("Sincronizza") {
                        Task { await syncBidirectional() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || !serverConfigured)
                }

                HStack(spacing: 10) {
                    Button("Carica su server") {
                        Task { await pushToServer() }
                    }
                    .disabled(isBusy || !serverConfigured || components.isEmpty)

                    Button("Scarica dal server") {
                        showPullConfirm = true
                    }
                    .disabled(isBusy || !serverConfigured)
                }

                if isBusy {
                    ProgressView("Sincronizzazione…")
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !lastSyncAt.isEmpty {
                    Text("Ultima sync: \(lastSyncAt)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("Sincronizza = merge bidirezionale (ultima modifica vince). Carica/Scarica = sovrascrittura unidirezionale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var autoSyncSection: some View {
        GroupBox("Sync automatica") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("All'avvio dell'app", isOn: $autoSyncOnLaunch)
                    .disabled(!serverConfigured)

                LabeledContent("Intervallo in background") {
                    Picker("Intervallo", selection: $autoSyncIntervalMinutes) {
                        Text("Disattivato").tag(0)
                        Text("15 minuti").tag(15)
                        Text("30 minuti").tag(30)
                        Text("60 minuti").tag(60)
                    }
                    .labelsHidden()
                    .disabled(!serverConfigured)
                }

                Text("La sync automatica aggiorna componenti e progetti con merge bidirezionale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pathsSection: some View {
        GroupBox("Percorsi") {
            LabeledContent("CSV inventario") {
                TextField("Percorso", text: $defaultCSVPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var lcscSection: some View {
        GroupBox("LCSC") {
            LabeledContent("Ritardo tra richieste (ms)") {
                HStack {
                    Slider(value: $lcscRequestDelayMs, in: 200...3000, step: 100)
                    Text("\(Int(lcscRequestDelayMs))")
                        .monospacedDigit()
                        .frame(width: 50)
                }
            }
        }
    }

    private var digiKeySection: some View {
        GroupBox("DigiKey") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Config") {
                    Text(digiKeyConfigured ? "digikey_config.yml ✓" : "Non trovato")
                        .foregroundStyle(digiKeyConfigured ? Color.primary : Color.orange)
                }
                LabeledContent("Token") {
                    Text(digiKeyTokenExists ? "Autenticato ✓" : "Non autenticato")
                        .foregroundStyle(digiKeyTokenExists ? Color.primary : Color.orange)
                }
                Text("python3 ~/Documents/Develop/ComponentVault/Tools/digikey_auth.py")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusPill(label: String, ok: Bool) -> some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ok ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .clipShape(Capsule())
    }

    private func remoteConfig() throws -> RemoteAPIConfig {
        try RemoteAPIConfig.from(baseURLString: apiBaseURL, apiKey: apiKey)
    }

    private func markSyncSuccess(remoteCount: Int? = nil, message: String) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        lastSyncAt = formatter.string(from: Date())
        if let remoteCount { lastRemoteCount = remoteCount }
        statusMessage = message
    }

    private func testConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let health = try await RemoteAPIClient.checkConnection(config: try remoteConfig())
            lastRemoteCount = health.components
            markSyncSuccess(remoteCount: health.components, message: "Connessione OK")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncBidirectional() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let message = try await SyncRunner.runFullSync(modelContext: modelContext)
            markSyncSuccess(message: message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pushToServer() async {
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let config = try remoteConfig()
            let count = try await store.pushToRemote(config: config)
            let projectStore = ProjectStore(modelContext: modelContext)
            let projectCount = try await projectStore.pushToRemote(config: config)
            markSyncSuccess(
                remoteCount: count,
                message: "Caricati \(count) componenti e \(projectCount) progetti"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pullFromServer() async {
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let config = try remoteConfig()
            let count = try await store.pullFromRemote(config: config)
            let projectStore = ProjectStore(modelContext: modelContext)
            let projectCount = try await projectStore.pullFromRemote(config: config, components: components)
            markSyncSuccess(
                remoteCount: count,
                message: "Scaricati \(count) componenti e \(projectCount) progetti"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: Component.self, inMemory: true)
}
