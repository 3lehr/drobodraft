import DroboKern
import SwiftUI

/// Blatt "Netzwerk-Drobo hinzufügen": Adresse eingeben, suchen, ein gefundenes Volume benennen und hinzufügen. Keine Kennungen in der Oberfläche.
struct NetzHinzufuegenBlatt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    @State private var adresse = ""
    @State private var name = "DroboPro"
    @State private var gesucht = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Netzwerk-Drobo hinzufügen").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Geben Sie die Adresse der DroboPro im lokalen Netzwerk ein. Sie finden sie in Ihrem Router. Die App sucht dort nach eingerichteten Volumes.").foregroundStyle(.secondary)
            HStack {
                TextField("Adresse der DroboPro", text: $adresse, prompt: Text("zum Beispiel 192.168.1.20")).textFieldStyle(.roundedBorder)
                    .onSubmit { suchen() }
                Button("Suchen") { suchen() }.disabled(adresse.trimmingCharacters(in: .whitespaces).isEmpty || m.netzSucheLaeuft)
            }
            if m.netzSucheLaeuft { ProgressView("Suche läuft …") }
            if let f = m.netzSucheFehler { Hinweis(symbol: "exclamationmark.triangle.fill", text: LocalizedStringKey(f), farbe: .orange) }
            if !m.netzTreffer.isEmpty {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                ForEach(m.netzTreffer, id: \.uuid) { t in
                    HStack {
                        Label("Volume \(t.lun + 1), \(groesseText(t.partitionBytes))", systemImage: "externaldrive.connected.to.line.below")
                        Spacer()
                        if m.einstellungen.drobos.contains(where: { $0.uuid == t.uuid }) { Text("bereits hinzugefügt").foregroundStyle(.secondary) }
                        else { Button("Hinzufügen") { m.netzHinzufuegen(host: gesucht, lun: t, name: name); dismiss() } }
                    }.accessibilityElement(children: .combine)
                }
            }
            HStack { Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }

    func suchen() { gesucht = adresse; m.netzSuchen(adresse) }
}
