import DroboKern
import SwiftUI

/// "Per Adresse hinzufügen" als Abschnitt in "Drobos finden": IPv4-Adresse eingeben, prüfen, ein gefundenes Volume benennen und hinzufügen. Keine Kennungen in der Oberfläche.
struct PerAdresseHinzufuegen: View {
    @EnvironmentObject var m: DroboModell
    @State private var adresse = ""
    @State private var name = "DroboPro"
    @State private var gesucht = ""

    /// Vier Zahlen 0...255 mit Punkten; mehr prueft die Oberflaeche nicht (privates Netz prueft der Kern).
    var gueltig: Bool {
        let t = adresse.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        return t.count == 4 && t.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    var body: some View {
        Karte(titel: "Per Adresse hinzufügen") {
            Text("Geben Sie die Adresse der DroboPro im lokalen Netzwerk ein. Sie finden sie in Ihrem Router. Die App sucht dort nach eingerichteten Volumes.").foregroundStyle(.secondary)
            HStack {
                TextField("Adresse der DroboPro", text: $adresse, prompt: Text("zum Beispiel 192.168.1.20")).textFieldStyle(.roundedBorder)
                    .onSubmit { pruefen() }
                Button("Prüfen") { pruefen() }.disabled(!gueltig || m.netzSucheLaeuft)
            }
            if !adresse.isEmpty && !gueltig { Label("Eine Adresse besteht aus vier Zahlen von 0 bis 255, getrennt durch Punkte.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            if m.netzSucheLaeuft { ProgressView("Suche läuft …") }
            if let f = m.netzSucheFehler { Hinweis(symbol: "exclamationmark.triangle.fill", text: LocalizedStringKey(f), farbe: .orange) }
            if !m.netzTreffer.isEmpty {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                ForEach(m.netzTreffer, id: \.uuid) { t in
                    HStack {
                        Label("Volume \(t.lun + 1), \(groesseText(t.partitionBytes))", systemImage: "externaldrive.connected.to.line.below")
                        Spacer()
                        if m.einstellungen.drobos.contains(where: { $0.uuid == t.uuid }) { Text("bereits hinzugefügt").foregroundStyle(.secondary) }
                        else { Button("Hinzufügen") { m.netzHinzufuegen(host: gesucht, lun: t, name: name) } }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }

    func pruefen() { gesucht = adresse; m.netzSuchen(adresse) }
}
