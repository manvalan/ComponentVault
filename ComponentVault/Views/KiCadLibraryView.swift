import SwiftUI

/// Sezione "Libreria KiCad": consultazione della libreria dell'utente (copia locale
/// dell'indice, aggiornata dalla cartella condivisa) e stato delle richieste di download.
struct KiCadLibraryView: View {
    @State private var library = KiCadLibraryStore.shared
    @State private var searchText = ""
    @State private var ownOnly = true
    @State private var jobs: [KiCadFetchJob] = []
    @State private var jobsError: String?
    @State private var worker: KiCadWorkerStatus?

    private var results: [KiCadLibraryEntry] {
        library.search(searchText, ownOnly: ownOnly)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    indexSummary
                    Picker("Mostra", selection: $ownOnly) {
                        Text("Componenti di \(library.displayName)").tag(true)
                        Text("Tutta la libreria").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text(results.count >= 500 ? "Primi 500 risultati" : "\(results.count) simboli")) {
                    if library.index == nil {
                        ContentUnavailableView(
                            String(localized: "Indice non disponibile"),
                            systemImage: "books.vertical",
                            description: Text("Scegli in Impostazioni la cartella condivisa con il Mac che ha KiCad: l'indice lo scrive il worker.")
                        )
                    }
                    ForEach(results) { entry in
                        entryRow(entry)
                    }
                }

                Section("Richieste di download") {
                    if let jobsError {
                        Text(jobsError).font(.caption).foregroundStyle(.red)
                    } else if jobs.isEmpty {
                        Text("Nessuna richiesta").foregroundStyle(.secondary)
                    }
                    ForEach(jobs) { job in
                        jobRow(job)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Nome, MPN, LCSC o footprint")
            .navigationTitle(library.displayName)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await reload() }
                    } label: {
                        if library.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Aggiorna", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(library.isRefreshing || !KiCadQueue.isAvailable)
                }
            }
            .task { await reload() }
        }
    }

    private var indexSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let index = library.index {
                Text("\(index.count) simboli · \(library.ownComponentsCount) componenti di \(library.displayName)")
                    .font(.headline)
                Text("Indice del \(index.generatedAt) · copia locale disponibile offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let worker {
                Label(
                    worker.isActive
                        ? String(localized: "Mac con KiCad attivo: \(worker.host)")
                        : String(localized: "Mac con KiCad non attivo (\(worker.host), visto \(worker.lastSeenDate.formatted(.relative(presentation: .named))))"),
                    systemImage: "desktopcomputer"
                )
                .font(.caption)
                .foregroundStyle(worker.isActive ? .green : .secondary)
            }
            if let error = library.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func entryRow(_ entry: KiCadLibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.name).font(.body.monospaced())
                Spacer()
                if let lcsc = entry.lcsc {
                    Text(lcsc).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if entry.model3d == true {
                    Image(systemName: "cube").foregroundStyle(.secondary).platformHelp("Modello 3D presente")
                }
            }
            Text(entry.lib + (entry.footprint.map { " · " + $0 } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func jobRow(_ job: KiCadFetchJob) -> some View {
        DisclosureGroup {
            ForEach(job.result?.components ?? []) { component in
                HStack {
                    Text(component.name).font(.caption.monospaced())
                    Spacer()
                    Text(component.status).font(.caption2)
                    if component.needsModelReview {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            if let error = job.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                Text(jobStatus(job.status))
                Spacer()
                Text("\(job.result?.components?.count ?? job.itemCount) componenti")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func jobStatus(_ status: String) -> String {
        switch status {
        case "queued": String(localized: "In coda")
        case "running": String(localized: "In lavorazione")
        case "done": String(localized: "Completata")
        case "partial": String(localized: "Completata in parte")
        case "failed": String(localized: "Non riuscita")
        default: status
        }
    }

    private func reload() async {
        await library.refresh()
        worker = await KiCadQueue.workerStatus()
        do {
            jobs = try await KiCadQueue.listJobs()
            jobsError = nil
        } catch {
            jobsError = error.localizedDescription
        }
    }
}

/// Verifica della BOM di un progetto contro la libreria KiCad e richiesta dei mancanti.
struct ProjectKiCadCheckView: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var library = KiCadLibraryStore.shared
    @State private var showFetch = false

    private struct Row: Identifiable {
        let id: String
        let designators: [String]
        let mpn: String
        let lcsc: String?
        let category: String
        let match: KiCadLibraryMatch
    }

    /// Righe BOM raggruppate per componente (lo stesso MPN su più designator conta una volta).
    private var rows: [Row] {
        var grouped: [String: (designators: [String], item: ProjectItem)] = [:]
        for item in project.items {
            let key = item.component.map { $0.mpn.isEmpty ? $0.lcscCode : $0.mpn } ?? "—\(item.designator)"
            grouped[key, default: ([], item)].designators.append(item.designator)
        }
        return grouped.map { key, value in
            let component = value.item.component
            let mpn = component?.mpn ?? ""
            let lcsc = component?.supplierLCSCCode
            return Row(
                id: key,
                designators: value.designators.sorted(),
                mpn: mpn,
                lcsc: lcsc,
                category: component?.category ?? "",
                match: component == nil ? .noPartNumber : library.match(mpn: mpn, lcsc: lcsc)
            )
        }
        .sorted { ($0.designators.first ?? "") < ($1.designators.first ?? "") }
    }

    private var missing: [Row] {
        rows.filter { if case .missing = $0.match { return !$0.mpn.isEmpty } else { return false } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let all = rows
                    let present = all.filter { if case .present = $0.match { true } else { false } }.count
                    LabeledContent("In libreria", value: "\(present) / \(all.count)")
                    LabeledContent("Da scaricare", value: "\(missing.count)")
                    if library.index == nil {
                        Text("Indice libreria non disponibile: serve la cartella condivisa con il Mac che ha KiCad.")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let generated = library.index?.generatedAt {
                        Text("Indice del \(generated)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        showFetch = true
                    } label: {
                        Label("Scarica i mancanti (\(missing.count))", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(missing.isEmpty || !KiCadQueue.isAvailable)
                }

                Section("Componenti") {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.mpn.isEmpty ? String(localized: "senza MPN") : row.mpn).font(.body.monospaced())
                                Text(row.designators.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            matchBadge(row.match)
                        }
                    }
                }
            }
            .navigationTitle("Libreria KiCad · \(project.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem {
                    Button {
                        Task { await library.refresh() }
                    } label: {
                        Label("Aggiorna indice", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isRefreshing)
                }
            }
            .task { await library.refresh() }
            .sheet(isPresented: $showFetch) {
                KiCadFetchView(
                    items: missing.map {
                        KiCadFetchItem(
                            mpn: String($0.mpn.prefix(128)),
                            lcsc: $0.lcsc,
                            ref: String($0.designators.joined(separator: ",").prefix(64)),
                            funzione: String($0.category.prefix(256))
                        )
                    },
                    title: String(localized: "Scarica mancanti")
                )
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    @ViewBuilder
    private func matchBadge(_ match: KiCadLibraryMatch) -> some View {
        switch match {
        case .present(let entry):
            VStack(alignment: .trailing, spacing: 2) {
                Label("In libreria", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(entry.lib).font(.caption2).foregroundStyle(.secondary)
            }
        case .missing:
            Label("Mancante", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .noPartNumber:
            Label("Senza MPN", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .unknown:
            Label("Da verificare", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}
