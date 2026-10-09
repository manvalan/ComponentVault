import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
    @Query(sort: \Component.lcscCode) private var allComponents: [Component]

    @State private var projectStore: ProjectStore?
    @State private var selection: Project?
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @State private var showImportBOM = false
    @State private var pendingImportURL: URL?
    @State private var importProjectName = ""
    @State private var showImportConfirm = false
    @State private var replaceExistingBOM = true
    @State private var importResult: BOMImportResult?
    @State private var importError: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(projects, selection: $selection) { project in
                    ProjectRowView(project: project)
                        .tag(project)
                }

                #if os(macOS)
                HStack {
                    Button {
                        showNewProject = true
                    } label: {
                        Label("Nuovo progetto", systemImage: "plus")
                    }
                    Button {
                        showImportBOM = true
                    } label: {
                        Label("Importa BOM EasyEDA", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                    Text("\(projects.count) progetti")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.bar)
                #else
                HStack {
                    Spacer()
                    Text("\(projects.count) progetti")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                #endif
            }
            .navigationSplitViewColumnWidth(
                min: AppLayout.projectsListMin,
                ideal: AppLayout.projectsListIdeal
            )
        } detail: {
            if let selection {
                ProjectDetailView(project: selection, projectStore: projectStore)
            } else {
                ContentUnavailableView(
                    String(localized: "Progetti BOM"),
                    systemImage: "folder",
                    description: Text("Crea un progetto per gestire la distinta base\ne verificare disponibilità componenti.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Progetti")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showNewProject = true
                    } label: {
                        Label("Nuovo progetto", systemImage: "plus")
                    }
                    Button {
                        showImportBOM = true
                    } label: {
                        Label("Importa BOM EasyEDA", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Progetto", systemImage: "plus")
                }
            }
        }
        #endif
        .onAppear {
            if projectStore == nil {
                projectStore = ProjectStore(modelContext: modelContext)
            }
        }
        .alert("Nuovo progetto", isPresented: $showNewProject) {
            TextField("Nome progetto", text: $newProjectName)
            Button("Annulla", role: .cancel) { newProjectName = "" }
            Button("Crea") { createProject() }
        } message: {
            Text("Es. DigiRadio, Amplificatore, PSU")
        }
        .alert("Importa BOM EasyEDA", isPresented: $showImportConfirm) {
            TextField("Nome progetto", text: $importProjectName)
            Button("Annulla", role: .cancel) {
                pendingImportURL = nil
                importProjectName = ""
            }
            Button(replaceExistingBOM ? "Importa (sostituisci)" : "Importa (aggiungi)") {
                performBOMImport()
            }
        } message: {
            if let pendingImportURL {
                let exists = projects.contains {
                    $0.name.localizedCaseInsensitiveCompare(importProjectName) == .orderedSame
                }
                Text(
                    exists
                        ? "Aggiorna «\(importProjectName)» da \(pendingImportURL.lastPathComponent).\n\(replaceExistingBOM ? "Le righe esistenti verranno sostituite." : "Le righe verranno unite a quelle esistenti.")"
                        : "Crea «\(importProjectName)» da \(pendingImportURL.lastPathComponent)."
                )
            }
        }
        .fileImporter(
            isPresented: $showImportBOM,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImportFileSelection(result)
        }
        .alert("Import BOM completato", isPresented: .constant(importResult != nil)) {
            Button("OK") { importResult = nil }
        } message: {
            if let result = importResult {
                if result.missingLCSC.isEmpty {
                    Text("Importate \(result.imported) righe nel progetto.")
                } else {
                    Text("Importate \(result.imported) righe.\n\nNon in inventario (\(result.missingLCSC.count)):\n\(result.missingLCSC.prefix(8).joined(separator: ", "))\(result.missingLCSC.count > 8 ? "…" : "")")
                }
            }
        }
        .alert("Errore import BOM", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: showImportConfirm) { _, isPresented in
            if isPresented {
                replaceExistingBOM = projects.contains {
                    $0.name.localizedCaseInsensitiveCompare(importProjectName) == .orderedSame
                }
            }
        }
    }

    private func createProject() {
        guard let projectStore, !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let project = try projectStore.createProject(name: newProjectName.trimmingCharacters(in: .whitespaces))
            selection = project
            newProjectName = ""
        } catch {
            // status shown via store if needed
        }
    }

    private func handleImportFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            pendingImportURL = url
            importProjectName = BOMImporter.suggestedProjectName(from: url)
            showImportConfirm = true
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func performBOMImport() {
        guard let projectStore, let url = pendingImportURL else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            pendingImportURL = nil
        }
        do {
            let outcome = try projectStore.importBOMCreatingProject(
                from: url,
                projectName: importProjectName,
                components: allComponents,
                replaceExisting: replaceExistingBOM
            )
            selection = outcome.project
            importResult = outcome.result
            importProjectName = ""
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct ProjectRowView: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack(spacing: 8) {
                Text("\(project.totalItems) componenti")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if project.missingCount > 0 {
                    Label("\(project.missingCount) mancanti", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
