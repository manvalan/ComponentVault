import SwiftUI
import UniformTypeIdentifiers

struct DigiKeyConfigEditorView: View {
    @Binding var digikey: AppConfig.DigiKey
    var onSaved: (() -> Void)? = nil

    @State private var rawYAML = ""
    @State private var useRawYAML = false
    @State private var showImportPanel = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showErrorAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Toggle("Modifica YAML grezzo (file completo)", isOn: $useRawYAML)

            if useRawYAML {
                rawEditor
            } else {
                formEditor
            }

            actionBar

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .onAppear(perform: loadFromDisk)
        .fileImporter(
            isPresented: $showImportPanel,
            allowedContentTypes: [.yaml, .plainText],
            allowsMultipleSelection: false
        ) { result in
            importYAML(result)
        }
        .alert("Errore", isPresented: $showErrorAlert) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppConfig.fileName)
                .font(.headline)
            Text(AppConfigIO.configFile.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Tutta la configurazione (server, sync, DigiKey, percorsi) è in questo unico file YAML.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var formEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Client ID") {
                TextField("Dal portale developer.digikey.com", text: $digikey.clientID)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Client Secret") {
                SecureField("Segreto applicazione", text: $digikey.clientSecret)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Ambiente") {
                Picker("Ambiente", selection: $digikey.environment) {
                    ForEach(DigiKeyEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("Callback Mac") {
                TextField("https://localhost:8443/digikey/callback", text: $digikey.callbackURL)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Callback iPad") {
                TextField(DigiKeyConfig.defaultIOSCallbackURL, text: $digikey.iosCallbackURL)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                LabeledContent("Market") {
                    TextField("IT", text: $digikey.market)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                LabeledContent("Valuta") {
                    TextField("EUR", text: $digikey.currency)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                LabeledContent("Lingua") {
                    TextField("it", text: $digikey.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
            }
        }
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("YAML completo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $rawYAML)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 280)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25))
                )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Salva") {
                saveConfig()
            }
            .buttonStyle(.borderedProminent)

            Button("Importa file…") {
                showImportPanel = true
            }
            .buttonStyle(.bordered)

            Button("Ricarica") {
                loadFromDisk()
            }
            .buttonStyle(.borderless)
        }
    }

    private func loadFromDisk() {
        let app = AppConfigIO.reload()
        digikey = app.digikey
        rawYAML = AppConfigIO.yamlString(for: app)
        statusMessage = "Config caricata da \(AppConfig.fileName)."
    }

    private func saveConfig() {
        do {
            if useRawYAML {
                let saved = try AppConfigIO.saveRawYAML(rawYAML)
                digikey = saved.digikey
            } else {
                var app = AppConfigIO.current()
                app.digikey = digikey
                guard app.isDigiKeyConfigured else {
                    throw DigiKeyConfigFileError.missingClientCredentials
                }
                _ = try AppConfigIO.save(app)
                rawYAML = AppConfigIO.yamlString(for: app)
            }
            statusMessage = "Salvato in \(AppConfig.fileName)"
            onSaved?()
        } catch {
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }

    private func importYAML(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                rawYAML = content
                if let parsed = AppConfigIO.parseYAML(content) {
                    digikey = parsed.digikey
                    useRawYAML = false
                    statusMessage = "Importato da \(url.lastPathComponent). Clicca Salva."
                } else if let legacy = DigiKeyConfig.parseYAML(content) {
                    digikey = AppConfig.DigiKey(legacy)
                    useRawYAML = false
                    statusMessage = "Importato digikey_config legacy. Clicca Salva per unificare."
                } else {
                    useRawYAML = true
                    statusMessage = "YAML grezzo importato — verifica e Salva."
                }
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showErrorAlert = true
        }
    }
}

private extension UTType {
    static var yaml: UTType {
        UTType(filenameExtension: "yml") ?? UTType(filenameExtension: "yaml") ?? .plainText
    }
}

#Preview {
    DigiKeyConfigEditorView(digikey: .constant(AppConfigIO.defaultTemplate().digikey))
        .frame(width: 560)
}
