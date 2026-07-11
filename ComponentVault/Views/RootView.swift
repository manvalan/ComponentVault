import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Component.lcscCode) private var components: [Component]

    @State private var isReady = false
    @State private var bootstrapError: String?

    var body: some View {
        Group {
            if isReady {
                ContentView()
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Caricamento inventario…")
                        .foregroundStyle(.secondary)
                    if let bootstrapError {
                        Text(bootstrapError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Riprova") {
                            Task { await loadInventory(force: true) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await loadInventory(force: false)
        }
    }

    private func loadInventory(force: Bool) async {
        guard force || components.isEmpty else {
            isReady = true
            return
        }

        let store = ComponentStore(modelContext: modelContext)
        do {
            if DatabaseBootstrap.isDatabaseAvailable() {
                _ = try await store.bootstrapFromDefaultLocation()
            } else if components.isEmpty {
                bootstrapError = "Database non trovato in /Users/michelebigi/LCSC"
                isReady = true
                return
            }
            bootstrapError = nil
        } catch {
            bootstrapError = error.localizedDescription
        }
        isReady = true
    }
}
