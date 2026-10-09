import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    private var autoSyncOnLaunch: Bool { FolderSync.autoSyncOnLaunch }
    private var autoSyncIntervalMinutes: Int { FolderSync.autoSyncIntervalMinutes }

    @State private var isBootstrapping = false
    @State private var bootstrapError: String?
    @State private var bootstrapBannerDismissed = false

    private static let legacyMigrationDoneKey = "ComponentVault.legacyInventoryMigrationDone"

    var body: some View {
        ContentView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isBootstrapping {
                    bootstrapProgressBanner
                } else if shouldShowBootstrapBanner {
                    bootstrapNoticeBanner
                }
            }
            .task {
                runInventoryMigrations()
                await loadInventoryIfNeeded()
                await runAutoSyncIfNeeded()
            }
            .task(id: autoSyncIntervalMinutes) {
                guard autoSyncIntervalMinutes > 0, FolderSync.isAvailable else { return }
                while !Task.isCancelled {
                    _ = try? await Task.sleep(for: .seconds(autoSyncIntervalMinutes * 60))
                    guard !Task.isCancelled else { return }
                    _ = try? await FolderSync.run(modelContext: modelContext)
                }
            }
            .onChange(of: components.count) { _, count in
                if count > 0 {
                    bootstrapError = nil
                    bootstrapBannerDismissed = false
                }
            }
    }

    private var shouldShowBootstrapBanner: Bool {
        !bootstrapBannerDismissed && bootstrapError != nil && components.isEmpty
    }

    private var bootstrapProgressBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Importazione inventario…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bootstrapNoticeBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(bootstrapError ?? "")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    #if os(iOS)
                    Button("Impostazioni") {
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    #endif
                    Button("Riprova") {
                        bootstrapBannerDismissed = false
                        Task { await loadInventoryIfNeeded() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Chiudi") {
                        bootstrapBannerDismissed = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.12))
    }

    private func runInventoryMigrations() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationDoneKey) else { return }

        let store = ComponentStore(modelContext: modelContext)
        do {
            let dkCount = try store.migrateLegacyInventoryCodesIfNeeded()
            let cvCount = try store.migrateLegacyPrimaryKeysToCVIfNeeded()
            if dkCount == 0 && cvCount == 0 {
                UserDefaults.standard.set(true, forKey: Self.legacyMigrationDoneKey)
            }
        } catch {
            // Migrazione silenziosa: non disturba l'utente; riproverà al prossimo avvio.
        }
    }

    private func loadInventoryIfNeeded() async {
        guard components.isEmpty else { return }

        // Un altro dispositivo ha già condiviso l'inventario nella cartella comune.
        if FolderSync.isAvailable, SharedFolder.isReachable {
            isBootstrapping = true
            defer { isBootstrapping = false }
            if (try? await FolderSync.run(modelContext: modelContext)) != nil,
               ((try? modelContext.fetchCount(FetchDescriptor<Component>())) ?? 0) > 0 {
                bootstrapError = nil
                return
            }
        }

        guard DatabaseBootstrap.isDatabaseAvailable() else {
            bootstrapError = String(localized: "Nessun dato locale. Scegli una cartella condivisa in Impostazioni oppure importa un CSV dell'inventario.")
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
        guard autoSyncOnLaunch, FolderSync.isAvailable else { return }
        _ = try? await FolderSync.run(modelContext: modelContext)
    }
}
