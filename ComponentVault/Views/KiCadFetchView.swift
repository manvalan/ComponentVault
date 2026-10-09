import SwiftUI

/// Chiede al Mac con KiCad (tramite la cartella condivisa) di aggiungere componenti
/// alla libreria KiCad dell'utente e mostra l'esito del worker (import, controllo pin/pad,
/// modello 3D), con lo zip KiCad e il render.
struct KiCadFetchView: View {
    let items: [KiCadFetchItem]
    var title: String = String(localized: "Libreria KiCad")
    @Environment(\.dismiss) private var dismiss

    init(items: [KiCadFetchItem], title: String = String(localized: "Libreria KiCad")) {
        self.items = items
        self.title = title
    }

    init(component: Component) {
        self.init(items: [KiCadFetchItem(
            mpn: String(component.mpn.prefix(128)),
            lcsc: component.supplierLCSCCode,
            funzione: String(component.category.prefix(256))
        )])
    }

    @State private var job: KiCadFetchJob?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var replaceExisting = false
    @State private var downloads: [String: URL] = [:]
    @State private var renders: [String: Image] = [:]
    @State private var worker: KiCadWorkerStatus?

    var body: some View {
        NavigationStack {
            Form {
                Section(items.count == 1 ? "Componente" : "Componenti (\(items.count))") {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.mpn.isEmpty ? "—" : item.mpn, value: item.lcsc ?? String(localized: "senza LCSC"))
                            .font(.callout.monospaced())
                    }
                    Toggle("Sostituisci se già in libreria", isOn: $replaceExisting)
                        .disabled(job != nil)
                }

                if let job {
                    Section("Richiesta") {
                        LabeledContent("Stato", value: statusLabel(job.status))
                        if !job.isFinished {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("In attesa del Mac con KiCad…").foregroundStyle(.secondary)
                            }
                            workerLabel
                        }
                        if let error = job.error, !error.isEmpty {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                    ForEach(job.result?.components ?? []) { item in
                        componentSection(item, jobID: job.id)
                    }
                } else {
                    Section {
                        Button {
                            Task { await submit() }
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Label("Aggiungi alla libreria KiCad", systemImage: "square.and.arrow.down.on.square")
                            }
                        }
                        .disabled(isSubmitting || items.isEmpty || items.contains { $0.mpn.isEmpty } || !KiCadQueue.isAvailable)
                        workerLabel
                    } footer: {
                        Text("Il download da SnapEDA, Ultra Librarian o JLCPCB/EasyEDA viene eseguito dal Mac con la libreria: le credenziali dei fornitori non passano mai da questo dispositivo.")
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .task(id: job?.id) { await pollUntilFinished() }
            .task { worker = await KiCadQueue.workerStatus() }
        }
        .frame(minWidth: 420, minHeight: 420)
    }

    @ViewBuilder
    private func componentSection(_ item: KiCadFetchComponent, jobID: String) -> some View {
        Section(item.name) {
            LabeledContent("Esito", value: statusLabel(item.status) + (item.source.map { " (\($0))" } ?? ""))
            if let detail = item.detail, !detail.isEmpty {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array((item.model3d ?? []).enumerated()), id: \.offset) { _, model in
                Label(
                    model.status == "WARN" ? "Modello 3D da verificare" : "Modello 3D: \(model.status)",
                    systemImage: model.status == "WARN" ? "exclamationmark.triangle" : "cube"
                )
                .foregroundStyle(model.status == "WARN" ? .orange : .primary)
                ForEach(model.messages ?? [], id: \.self) { Text($0).font(.footnote) }
            }
            if let image = renders[item.name] {
                image.resizable().scaledToFit().frame(maxHeight: 220)
                Text("Controlla il pin 1 nel render.").font(.footnote).foregroundStyle(.secondary)
            }
            if let file = item.kicadFile {
                if let url = downloads[file] {
                    ShareLink(item: url) { Label("Condividi \(file)", systemImage: "square.and.arrow.up") }
                } else {
                    Button {
                        Task { await download(file, jobID: jobID) }
                    } label: {
                        Label("Scarica file KiCad (\(file))", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        .task(id: item.renderFile) {
            if let render = item.renderFile, renders[item.name] == nil {
                await loadRender(render, name: item.name, jobID: jobID)
            }
        }
    }

    @ViewBuilder
    private var workerLabel: some View {
        if !KiCadQueue.isAvailable {
            Label("Scegli una cartella condivisa in Impostazioni.", systemImage: "folder.badge.questionmark")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if let worker, worker.isActive {
            Label("Mac con KiCad attivo: \(worker.host)", systemImage: "desktopcomputer")
                .font(.footnote)
                .foregroundStyle(.green)
        } else {
            Label("Mac con KiCad non attivo: la richiesta resta in coda finché non si avvia il worker.", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "queued": String(localized: "In coda")
        case "running": String(localized: "In lavorazione")
        case "done": String(localized: "Completata")
        case "partial": String(localized: "Completata in parte")
        case "failed", "FAILED": String(localized: "Non riuscita")
        case "IMPORTED": String(localized: "Importato")
        case "PRESENT": String(localized: "Già in libreria")
        case "SKIPPED": String(localized: "Saltato")
        default: status
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            job = try await KiCadQueue.createJob(items, update: replaceExisting)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollUntilFinished() async {
        while let current = job, !current.isFinished, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            do {
                job = try await KiCadQueue.job(id: current.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if job?.isFinished == true {
            // Il worker ha riscritto l'indice: aggiorna lo stato "in libreria".
            await KiCadLibraryStore.shared.refresh()
        }
    }

    private func download(_ name: String, jobID: String) async {
        do {
            downloads[name] = try await KiCadQueue.file(jobID: jobID, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadRender(_ name: String, name component: String, jobID: String) async {
        guard let url = try? await KiCadQueue.file(jobID: jobID, name: name) else { return }
        #if os(macOS)
        if let image = NSImage(contentsOf: url) { renders[component] = Image(nsImage: image) }
        #else
        if let image = UIImage(contentsOfFile: url.path) { renders[component] = Image(uiImage: image) }
        #endif
    }
}
