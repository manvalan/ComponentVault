import SwiftUI
import SwiftData

struct ProjectsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]

    @State private var projectStore: ProjectStore?
    @State private var selection: Project?
    @State private var showNewProject = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(projects, selection: $selection) { project in
                    ProjectRowView(project: project)
                        .tag(project)
                }

                HStack {
                    Button {
                        showNewProject = true
                    } label: {
                        Label("Nuovo progetto", systemImage: "plus")
                    }
                    Spacer()
                    Text("\(projects.count) progetti")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.bar)
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
                    "Progetti BOM",
                    systemImage: "folder",
                    description: Text("Crea un progetto per gestire la distinta base\ne verificare disponibilità componenti.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
