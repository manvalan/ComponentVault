import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @AppStorage("autoSyncOnLaunch") private var autoSyncOnLaunch = false
    @AppStorage("autoSyncIntervalMinutes") private var autoSyncIntervalMinutes = 0

    @State private var isBootstrapping = false
    @State private var bootstrapError: String?

    var body: some View {
        ContentView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isBootstrapping {
                    ZStack {
                        Color.black.opacity(0.12)
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Importazione inventario…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                } else if let bootstrapError, components.isEmpty {
                    ZStack {
                        Color.black.opacity(0.08)
                        VStack(spacing: 10) {
                            Text(bootstrapError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                            Button("Riprova") {
                                Task { await loadInventoryIfNeeded() }
                            }
                        }
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .task {
                await loadInventoryIfNeeded()
                await runAutoSyncIfNeeded()
            }
            .task(id: autoSyncIntervalMinutes) {
                guard autoSyncIntervalMinutes > 0, SyncSettings.isConfigured else { return }
                while !Task.isCancelled {
                    _ = try? await Task.sleep(for: .seconds(autoSyncIntervalMinutes * 60))
                    guard !Task.isCancelled else { return }
                    _ = try? await SyncRunner.runFullSync(modelContext: modelContext)
                }
            }
    }

    private func loadInventoryIfNeeded() async {
        guard components.isEmpty else { return }

        #if os(iOS)
        if !DatabaseBootstrap.isDatabaseAvailable(), SyncSettings.isConfigured {
            isBootstrapping = true
            defer { isBootstrapping = false }
            if let message = try? await SyncRunner.runFullSync(modelContext: modelContext) {
                bootstrapError = nil
                if !message.isEmpty { return }
            }
        }
        #endif

        guard DatabaseBootstrap.isDatabaseAvailable() else {
            #if os(iOS)
            bootstrapError = """
            Nessun dato locale. Configura server e API key in Impostazioni, poi sincronizza — oppure importa un CSV dall'inventario.
            """
            #else
            bootstrapError = "Database non trovato in \(AppPaths.lcscDataRoot.path)"
            #endif
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }

        let store = ComponentStore(modelContext: modelContext)
        do {
            _ = try await store.bootstrapFromDefaultLocation()
            bootstrapError = nil
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    private func runAutoSyncIfNeeded() async {
        guard autoSyncOnLaunch, SyncSettings.isConfigured else { return }
        _ = try? await SyncRunner.runFullSync(modelContext: modelContext)
    }
}
