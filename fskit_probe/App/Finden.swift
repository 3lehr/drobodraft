import DroboKern
import SwiftUI

/// "Drobos finden": ein Ort fuer Suche (USB + lokales Netzwerk, laeuft im Hilfsdienst) und Eingabe per Adresse. Nichts wird automatisch uebernommen.
struct DrobosFindenAnsicht: View {
    @EnvironmentObject var m: DroboModell

    var bekannte: [DroboEintrag] { m.einstellungen.drobos.filter { m.sucheBekannt.contains($0.uuid) } }
    var nichtsGefunden: Bool { m.erkannte.isEmpty && m.lanErkannte.isEmpty && bekannte.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Abstand.l) {
                Text("Drobos finden").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Text("Die App sucht angeschlossene Drobos (USB) und DroboPros im lokalen Netzwerk. Gefundene Drobos werden erst nach „Hinzufügen“ übernommen.").foregroundStyle(.secondary)
                HStack(spacing: Abstand.m) {
                    Button { m.drobosSuchen() } label: { Label(m.sucheLaeuft ? "Suche läuft …" : "Suchen", systemImage: "magnifyingglass") }
                        .disabled(m.sucheLaeuft)
                    if m.sucheLaeuft { ProgressView().controlSize(.small).accessibilityLabel("Suche läuft …") }
                }
                if let i = m.sucheInfo { Hinweis(symbol: "info.circle", text: LocalizedStringKey(i), farbe: .blue) }
                if !m.erkannte.isEmpty {
                    Karte(titel: "Per USB angeschlossen") {
                        ForEach(m.erkannte, id: \.uuid) { e in
                            HStack {
                                Label("\(e.name.isEmpty ? "Drobo" : e.name), \(groesseText(e.groesse))", systemImage: "externaldrive")
                                Spacer(); Button("Hinzufügen") { m.hinzufuegen(e) }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
                if !m.lanErkannte.isEmpty {
                    Karte(titel: "Im Netzwerk") {
                        ForEach(m.lanErkannte, id: \.host) { d in
                            HStack {
                                Label("DroboPro (\(d.host))", systemImage: "network")
                                Spacer(); Button("Hinzufügen") { m.lanHinzufuegen(d) }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
                if !bekannte.isEmpty {
                    Karte(titel: "Schon hinzugefügt") {
                        ForEach(bekannte, id: \.uuid) { e in
                            Label { Text("\(e.name), \(e.netz == nil ? String(localized: "USB") : String(localized: "Netzwerk"))") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
                                .accessibilityElement(children: .combine)
                        }
                    }
                }
                if nichtsGefunden && !m.sucheLaeuft {
                    Hinweis(symbol: "questionmark.circle", text: "Noch keine neue Drobo gefunden. Prüfe, ob die Drobo eingeschaltet und per USB oder im selben Netzwerk verbunden ist, und wähle „Suchen“. Du kannst die Adresse einer DroboPro auch unten eingeben.", farbe: .blue)
                }
                PerAdresseHinzufuegen()
            }.padding()
        }
    }
}
