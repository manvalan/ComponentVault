import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultCSVPath") private var defaultCSVPath = "/Users/michelebigi/LCSC/Componenti Elettronici.csv"
    @AppStorage("lcscRequestDelayMs") private var lcscRequestDelayMs = 800.0

    var body: some View {
        Form {
            Section("Percorsi") {
                LabeledContent("CSV inventario predefinito") {
                    TextField("Percorso", text: $defaultCSVPath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("LCSC") {
                LabeledContent("Ritardo tra richieste (ms)") {
                    Slider(value: $lcscRequestDelayMs, in: 200...3000, step: 100)
                    Text("\(Int(lcscRequestDelayMs))")
                        .monospacedDigit()
                        .frame(width: 50)
                }
                Text("Riduce il rischio di rate-limit durante l'arricchimento batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Roadmap") {
                LabeledContent("Server API", value: "michelebigi.it (futuro)")
                LabeledContent("Provider", value: "LCSC ✓ · DigiKey (pianificato)")
                LabeledContent("Piattaforme", value: "macOS ✓ · iPad (pianificato)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 320)
        .padding()
    }
}

#Preview {
    SettingsView()
}
