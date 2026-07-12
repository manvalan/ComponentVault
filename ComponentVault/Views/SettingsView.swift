import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @State private var config = AppConfigIO.current()
    @State private var configStatusMessage: String?

    @State private var store: ComponentStore?
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showPullConfirm = false
    @State private var digiKeyRedirectURL = ""
    @State private var digiKeyStatusMessage: String?
    @State private var isDigiKeyBusy = false
    @State private var digiKeyLoginTask: Task<Void, Never>?
    @State private var digiKeyTokenExists = FileManager.default.fileExists(
        atPath: AppPaths.digiKeyTokenCachePath
    )
    @State private var digiKeyConfigNonce = 0
    @State private var digiKeyConfigExpanded = !AppConfigIO.current().isDigiKeyConfigured

    private var digiKeyConfigured: Bool {
        _ = digiKeyConfigNonce
        return config.isDigiKeyConfigured
    }

    private var serverConfigured: Bool {
        config.isServerConfigured
    }

    var body: some View {
        Group {
            #if os(iOS)
            NavigationStack {
                settingsScrollContent
            }
            #else
            settingsScrollContent
            #endif
        }
        .onAppear {
            if store == nil { store = ComponentStore(modelContext: modelContext) }
            config = AppConfigIO.reload()
            refreshDigiKeyTokenStatus()
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

    private var settingsScrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    configFileSection
                    serverSection
                    digiKeySection
                        .id("digikey-settings")
                    syncSection
                    autoSyncSection
                    pathsSection
                    lcscSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                if !digiKeyConfigured {
                    scrollToDigiKey(proxy)
                }
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                scrollToDigiKey(proxy)
            }
            #endif
        }
        .navigationTitle("Impostazioni")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }

    private func scrollToDigiKey(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation {
                proxy.scrollTo("digikey-settings", anchor: .top)
            }
        }
    }

    private var configFileSection: some View {
        GroupBox("Configurazione") {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppConfigIO.configFile.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Salva tutto") {
                        saveFullConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Ricarica") {
                        config = AppConfigIO.reload()
                        configStatusMessage = "Ricaricato da \(AppConfig.fileName)"
                    }
                    .buttonStyle(.bordered)
                }
                if let configStatusMessage {
                    Text(configStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Server, sync, percorsi, LCSC e DigiKey sono in un unico \(AppConfig.fileName). Il vecchio digikey_config.yml viene migrato automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func saveFullConfig() {
        do {
            _ = try AppConfigIO.save(config)
            digiKeyConfigNonce += 1
            configStatusMessage = "Salvato \(AppConfig.fileName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var serverSection: some View {
        GroupBox("Server remoto") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("URL API") {
                    TextField("https://cvault.michelebigi.it", text: $config.server.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API key") {
                    SecureField("Chiave segreta", text: $config.server.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    statusPill(
                        label: serverConfigured ? "Configurato" : "Incompleto",
                        ok: serverConfigured
                    )
                    if config.sync.lastRemoteCount >= 0 {
                        Text("Server: \(config.sync.lastRemoteCount) componenti")
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

                if !config.sync.lastSyncAt.isEmpty {
                    Text("Ultima sync: \(config.sync.lastSyncAt)")
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
                Toggle("All'avvio dell'app", isOn: $config.sync.autoOnLaunch)
                    .disabled(!serverConfigured)

                LabeledContent("Intervallo in background") {
                    Picker("Intervallo", selection: $config.sync.intervalMinutes) {
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
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Cartella LCSC") {
                    Text(AppPaths.lcscDataRoot.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("CSV inventario") {
                    TextField("Percorso", text: $config.paths.csv)
                        .textFieldStyle(.roundedBorder)
                }
                #if os(iOS)
                Text("Su iPad i dati arrivano principalmente dal sync remoto o da import CSV.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                #endif
            }
        }
    }

    private var lcscSection: some View {
        GroupBox("LCSC") {
            LabeledContent("Ritardo tra richieste (ms)") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(config.lcsc.requestDelayMs) },
                            set: { config.lcsc.requestDelayMs = Int($0) }
                        ),
                        in: 200...3000,
                        step: 100
                    )
                    Text("\(config.lcsc.requestDelayMs)")
                        .monospacedDigit()
                        .frame(width: 50)
                }
            }
        }
    }

    private var digiKeySection: some View {
        GroupBox("DigiKey") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    statusPill(label: digiKeyConfigured ? "Config ✓" : "Config mancante", ok: digiKeyConfigured)
                    statusPill(label: digiKeyTokenExists ? "Token ✓" : "Non autenticato", ok: digiKeyTokenExists)
                }

                DisclosureGroup(
                    isExpanded: $digiKeyConfigExpanded,
                    content: {
                        DigiKeyConfigEditorView(digikey: $config.digikey) {
                            digiKeyConfigNonce += 1
                            config = AppConfigIO.current()
                        }
                    },
                    label: {
                        Label(
                            digiKeyConfigured ? "Modifica DigiKey" : "Configura DigiKey",
                            systemImage: digiKeyConfigured ? "pencil" : "exclamationmark.triangle"
                        )
                    }
                )

                if !digiKeyConfigured {
                    Text("Compila client_id e client_secret, poi Salva tutto o Salva nella sezione DigiKey.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if digiKeyConfigured, let dk = DigiKeyConfig.load() {
                    Text("Ambiente: \(dk.environment.label) · \(dk.apiBaseURL)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Redirect Mac: \(dk.callbackURL)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    #if os(iOS)
                    Text("Redirect iPad (portale DigiKey): \(dk.iosOAuthRedirectURI)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    #endif
                }

                if digiKeyConfigured {
                    #if os(macOS)
                    HStack(spacing: 10) {
                        Button("Apri login DigiKey") {
                            digiKeyLoginTask?.cancel()
                            digiKeyLoginTask = Task { await startDigiKeyLogin() }
                        }
                        .disabled(isDigiKeyBusy)

                        if isDigiKeyBusy {
                            Button("Annulla") {
                                digiKeyLoginTask?.cancel()
                                isDigiKeyBusy = false
                                digiKeyStatusMessage = "Annullato."
                            }
                        }

                        Button("Rinnova token") {
                            Task { await refreshDigiKeyToken() }
                        }
                        .disabled(isDigiKeyBusy || !digiKeyTokenExists)
                    }
                    #else
                    HStack(spacing: 10) {
                        Button("Apri login DigiKey") {
                            Task { await startDigiKeyLoginIOS() }
                        }
                        .disabled(isDigiKeyBusy)

                        Button("Rinnova token") {
                            Task { await refreshDigiKeyToken() }
                        }
                        .disabled(isDigiKeyBusy || !digiKeyTokenExists)
                    }
                    Text("DigiKey accetta solo redirect HTTPS. Registra nel portale l'URI sopra (es. cvault.michelebigi.it/…), non componentvault://.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    #endif

                    DisclosureGroup("Connessione manuale (fallback)") {
                        TextField("Incolla URL o solo il code dalla barra indirizzi", text: $digiKeyRedirectURL)
                            .textFieldStyle(.roundedBorder)

                        Button("Connetti manualmente") {
                            Task { await connectDigiKey() }
                        }
                        .disabled(digiKeyRedirectURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if isDigiKeyBusy {
                    ProgressView("Autenticazione DigiKey…")
                }

                if let digiKeyStatusMessage {
                    Text(digiKeyStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if os(macOS)
                Text("Un clic: server HTTPS locale → login DigiKey → token salvato. Il rinnovo è automatico finché il refresh token è valido.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                #endif

                LabeledContent("Ritardo tra richieste bulk (ms)") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(config.digikey.requestDelayMs) },
                                set: { config.digikey.requestDelayMs = Int($0) }
                            ),
                            in: 200...3000,
                            step: 100
                        )
                        Text("\(config.digikey.requestDelayMs)")
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func refreshDigiKeyTokenStatus() {
        digiKeyTokenExists = FileManager.default.fileExists(atPath: AppPaths.digiKeyTokenCachePath)
    }

    #if os(macOS)
    private func startDigiKeyLogin() async {
        guard !Task.isCancelled else { return }
        guard let config = DigiKeyConfig.load() else { return }

        let auth = DigiKeyAuthService(config: config)
        let loginURL = await auth.authorizationURL

        guard config.supportsLocalCallbackServer else {
            errorMessage = "callback_url senza porta. Usa es. https://localhost:8443/digikey/callback"
            return
        }

        isDigiKeyBusy = true
        digiKeyStatusMessage = "Avvio server OAuth su \(config.callbackURL)…"

        do {
            let code = try await DigiKeyOAuthCallbackServer.captureAuthorizationCode(
                callbackURL: config.callbackURL
            ) {
                if let warmupURL = URL(string: config.callbackURL) {
                    ExternalURLService.open(warmupURL)
                    digiKeyStatusMessage = "Se il browser avvisa sul certificato, clicca Continua/Avanzate."
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard !Task.isCancelled else { return }
                    ExternalURLService.open(loginURL)
                    digiKeyStatusMessage = "Login DigiKey aperto — clicca Allow."
                }
            }

            guard !Task.isCancelled else { return }

            digiKeyStatusMessage = "Codice ricevuto, scambio token…"
            try await auth.exchangeAuthorizationCode(code)
            refreshDigiKeyTokenStatus()
            if let expiry = await auth.tokenExpiryDescription {
                digiKeyStatusMessage = "Autenticato. Scadenza token: \(expiry)"
            } else {
                digiKeyStatusMessage = "Autenticato con successo."
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                digiKeyStatusMessage = "Auto-login fallito. Apri «Connessione manuale» e incolla l'URL dal browser."
            }
        }

        isDigiKeyBusy = false
        digiKeyLoginTask = nil
    }
    #endif

    #if os(iOS)
    private func startDigiKeyLoginIOS() async {
        guard let config = DigiKeyConfig.load() else { return }
        isDigiKeyBusy = true
        digiKeyStatusMessage = "Apertura login DigiKey…"
        defer { isDigiKeyBusy = false }

        let auth = DigiKeyAuthService(config: config)
        do {
            let code = try await DigiKeyOAuthFlow.authorize(config: config)
            try await auth.exchangeAuthorizationCode(code, redirectURI: config.iosOAuthRedirectURI)
            refreshDigiKeyTokenStatus()
            if let expiry = await auth.tokenExpiryDescription {
                digiKeyStatusMessage = "Autenticato. Scadenza token: \(expiry)"
            } else {
                digiKeyStatusMessage = "Autenticato con successo."
            }
        } catch {
            errorMessage = error.localizedDescription
            digiKeyStatusMessage = "Login fallito. Prova la connessione manuale."
        }
    }
    #endif

    private func connectDigiKey() async {
        guard let config = DigiKeyConfig.load() else { return }
        isDigiKeyBusy = true
        defer { isDigiKeyBusy = false }
        let auth = DigiKeyAuthService(config: config)
        do {
            try await auth.authenticate(withRedirectURL: digiKeyRedirectURL)
            refreshDigiKeyTokenStatus()
            digiKeyRedirectURL = ""
            if let expiry = await auth.tokenExpiryDescription {
                digiKeyStatusMessage = "Autenticato. Scadenza token: \(expiry)"
            } else {
                digiKeyStatusMessage = "Autenticato con successo."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshDigiKeyToken() async {
        guard let config = DigiKeyConfig.load() else { return }
        isDigiKeyBusy = true
        defer { isDigiKeyBusy = false }
        let auth = DigiKeyAuthService(config: config)
        do {
            try await auth.forceRefresh()
            refreshDigiKeyTokenStatus()
            if let expiry = await auth.tokenExpiryDescription {
                digiKeyStatusMessage = "Token rinnovato. Scadenza: \(expiry)"
            } else {
                digiKeyStatusMessage = "Token rinnovato."
            }
        } catch {
            errorMessage = error.localizedDescription
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
        try RemoteAPIConfig.from(
            baseURLString: config.server.apiBaseURL,
            apiKey: config.server.apiKey
        )
    }

    private func markSyncSuccess(remoteCount: Int? = nil, message: String) {
        var updated = AppConfigIO.current()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        updated.sync.lastSyncAt = formatter.string(from: Date())
        if let remoteCount { updated.sync.lastRemoteCount = remoteCount }
        try? AppConfigIO.save(updated)
        config = AppConfigIO.current()
        statusMessage = message
    }

    private func testConnection() async {
        try? AppConfigIO.save(config)
        isBusy = true
        defer { isBusy = false }
        do {
            let health = try await RemoteAPIClient.checkConnection(config: try remoteConfig())
            markSyncSuccess(remoteCount: health.components, message: "Connessione OK")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncBidirectional() async {
        try? AppConfigIO.save(config)
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
        try? AppConfigIO.save(config)
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
        try? AppConfigIO.save(config)
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
