import Foundation
import SwiftData

@MainActor
enum SyncRunner {
    static func runFullSync(modelContext: ModelContext) async throws -> String {
        let config = try SyncSettings.remoteConfig()
        let componentStore = ComponentStore(modelContext: modelContext)
        let projectStore = ProjectStore(modelContext: modelContext)

        let componentResult = try await componentStore.syncBidirectional(config: config)
        let components = try modelContext.fetch(FetchDescriptor<Component>())
        let projectResult = try await projectStore.syncBidirectional(
            config: config,
            components: components
        )

        let health = try await RemoteAPIClient.checkConnection(config: config)
        var message = "Componenti \(componentResult.summary)"
        if await RemoteAPIClient.projectsAPIAvailable(config: config) {
            message += " · Progetti \(projectResult.summary)"
        } else {
            message += " · Progetti: server da aggiornare (v0.4)"
        }
        SyncSettings.markSyncSuccess(remoteCount: health.components, message: message)
        return message
    }
}
