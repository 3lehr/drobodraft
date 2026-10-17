import DroboKern
import SwiftUI

struct UebersichtAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @Binding var rwFrage: Bool
    @Binding var anleitung: Bool
    var finden: () -> Void

    var body: some View {
        ScrollView {
            if let a = m.aktuell {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ZustandPunkt(stufe: a.stufe, gesamt: a.hwZustand)
                        Text(a.eintrag.name).font(.largeTitle).accessibilityAddTraits(.isHeader)
                        Spacer()
                        FruehAlphaAbzeichen()
                    }
                    Text(a.zustandText).font(.title3).foregroundStyle(.secondary)
                    if a.eintrag.netz != nil && !a.verbunden {
                        Hinweis(symbol: "wifi.exclamationmark", text: "Die DroboPro ist nicht erreichbar. Prüfen Sie, ob sie eingeschaltet und mit dem Netzwerk verbunden ist, und wählen Sie links „Drobos finden“.", farbe: .orange)
                    }
                    if a.eintrag.rolle == .timemachine {
                        Hinweis(symbol: "clock.arrow.circlepath", text: "Dieses Laufwerk ist als Time-Machine-Ziel eingetragen. Die App zeigt nur den Anschluss; macOS verwaltet das Laufwerk und die App hängt es nie selbst ein.", farbe: .blue)
                    }
                    if let h = a.hw, let g = a.hwZustand {
                        let geraet = VStack(spacing: 6) {
                            DroboGeraet(h: h, g: g, mitFehler: a.eintrag.netz == nil)
                            if let p = g.belegtProzent { Text("Physisch belegt: \(p) %").font(.callout).foregroundStyle(.secondary) }
                            #if DEBUG
                            // Demo: Popover laesst sich ohne Klick nicht fotografieren -> Einzelheiten des Schachts DROBO_DEMO_SCHACHT stehen darunter
                            if let n = DemoDaten.schacht { SchachtDetail(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: a.eintrag.netz == nil).background(.background.secondary, in: RoundedRectangle(cornerRadius: 8)) }
                            #endif
                        }
                        let zustand = ZustandsSpalte(g: g, gelb: a.netz?.gelbProzent ?? 85, rot: a.netz?.rotProzent ?? 95)
                        ViewThatFits(in: .horizontal) {   // breites Geraet (8 senkrechte Schaechte): Spalte rutscht darunter
                            HStack(alignment: .top, spacing: 24) { geraet; zustand }
                            VStack(alignment: .leading, spacing: 14) { geraet; zustand }
                        }
                    } else if a.eintrag.rolle != .timemachine {
                        LaufwerkeAnsicht.KeineDaten(netz: a.eintrag.netz != nil)
                    }
                    if a.eintrag.rolle != .timemachine {
                        if m.festplattenzugriff == String(localized: "fehlt") && a.eintrag.netz == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Hinweis(symbol: "lock.trianglebadge.exclamationmark", text: "Der Hilfsdienst darf nicht auf das Laufwerk zugreifen. Ohne Festplattenvollzugriff lässt sich die Drobo nicht einhängen.", farbe: .red)
                                Button("Systemeinstellungen öffnen") { m.festplattenzugriffOeffnen() }
                            }
                        }
                        if let g = a.merker.offenePruefung {
                            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Vor dem nächsten Einhängen wird geprüft: \(g)", farbe: .red)
                        }
                        Karte(titel: "Einhängung") {
                            if let nz = a.eintrag.netz { Zeile(name: "Adresse", wert: nz.host) }
                            if a.eingehaengt {
                                Zeile(name: "Ort", wert: a.ort)
                                Button { m.imFinderOeffnen() } label: { Label("Im Finder öffnen", systemImage: "folder") }.keyboardShortcut("o", modifiers: .command)
                                Zeile(name: "Treiber", wert: "\(a.treiber) · " + (a.nurlesen ? String(localized: "nur lesen") : String(localized: "schreiben")))
                            } else { Text("Nicht eingehängt.").foregroundStyle(.secondary) }
                            if let t = m.tempo.last(where: { $0.uuid == a.eintrag.uuid }) {
                                Zeile(name: "Tempo zuletzt", wert: String(format: "%.0f MB/s (%@)", t.mbProSekunde, t.art == "lesen" ? String(localized: "lesen") : String(localized: "schreiben")))
                            }
                            AktionsZeile(a: a, rwFrage: $rwFrage)
                        }
                        if let p = a.merker.letztePruefung {
                            Label { Text("Dateisystem zuletzt geprüft: \(zeitLesbar(p.zeit)), \(p.ok ? String(localized: "in Ordnung") : String(localized: "mit Auffälligkeiten"))") } icon: {
                                Image(systemName: p.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(p.ok ? Color.green : Color.red)
                            }.accessibilityElement(children: .combine)
                            if !p.ok { Text(p.probleme.joined(separator: "\n")).font(.callout) }
                        }
                        Details(a: a)
                        if m.spotlightHinweisNoetig {
                            VStack(alignment: .leading, spacing: 8) {
                                Hinweis(symbol: "magnifyingglass", text: "Spotlight ist für die Drobo nicht ausgeschlossen. Beim Schreiben bremst das und verändert das Laufwerk. Der Ausschluss ist freiwillig.")
                                Button("Anleitung") { anleitung = true }
                            }
                        }
                    }
                }.padding(20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keine Drobo eingerichtet. Mit „Drobos finden“ sucht die App angeschlossene Drobos und DroboPros im lokalen Netzwerk.")
                    Button { finden() } label: { Label("Drobos finden", systemImage: "magnifyingglass") }
                }.padding(20)
            }
        }
    }
}

/// Rechte Spalte: Zustand mit Schlagzeile, genau eine Empfehlung, Schutz und die Aufteilung belegt / frei / fuer Schutz reserviert (Seite 02).
struct ZustandsSpalte: View {
    let g: Gesamtzustand
    let gelb: Int, rot: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(g.schlagzeile.text).font(.title2.bold()) } icon: { Image(systemName: g.symbol).foregroundStyle(g.farbe).imageScale(.large) }
                .accessibilityElement(children: .combine).accessibilityLabel("\(g.stufeWort): \(g.schlagzeile.text)").accessibilityAddTraits(.isHeader)
            if let t = g.platzText(gelb: gelb, rot: rot) { Text(t) }
            if let e = g.empfehlungText { Label { Text(e).fontWeight(.semibold) } icon: { Image(systemName: "arrow.right.circle.fill").foregroundStyle(Color.accentColor) }.accessibilityElement(children: .combine) }
            if let s = g.schutzText { Text(s).foregroundStyle(.secondary) }
            if g.belegt + g.frei > 0 { Aufteilung(g: g) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Aufteilung: View {
    let g: Gesamtzustand
    var body: some View {
        let summe = Double(max(g.belegt + g.frei + g.reserviert, 1))
        VStack(alignment: .leading, spacing: 6) {
            Text("Aufteilung").font(.headline).accessibilityAddTraits(.isHeader)
            GeometryReader { p in
                HStack(spacing: 2) {
                    Rectangle().fill(Color.blue).frame(width: p.size.width * Double(g.belegt) / summe)
                    Rectangle().fill(Color.gray.opacity(0.55)).frame(width: p.size.width * Double(g.frei) / summe)
                    Rectangle().fill(Color.orange.opacity(0.7)).frame(width: p.size.width * Double(g.reserviert) / summe)
                }.clipShape(RoundedRectangle(cornerRadius: 4))
            }.frame(height: 12).accessibilityHidden(true)
            zeile("Belegt", g.belegt, Color.blue, "square.fill")
            zeile("Frei", g.frei, Color.gray, "square")
            if g.reserviert > 0 { zeile("Für Schutz reserviert", g.reserviert, Color.orange, "square.lefthalf.filled") }
        }
    }
    func zeile(_ name: LocalizedStringKey, _ b: UInt64, _ farbe: Color, _ symbol: String) -> some View {
        HStack { Image(systemName: symbol).foregroundStyle(farbe).accessibilityHidden(true); Text(name); Spacer(); Text(groesseText(b)).monospacedDigit() }.font(.callout).accessibilityElement(children: .combine)
    }
}

/// Technische Einzelheiten: die virtuelle Groesse des Dateisystems (HFS) gehoert hierher, nicht in die Hauptaussage.
struct Details: View {
    let a: DroboAnsicht
    @State private var auf = false
    var body: some View {
        DisclosureGroup("Details", isExpanded: $auf) {
            VStack(alignment: .leading, spacing: 8) {
                let vol: (belegt: UInt64, gesamt: UInt64, stand: String?)? = a.eingehaengt && a.gesamt > 0 ? (a.belegt, a.gesamt, nil) : a.belegungVH.map { ($0.belegt, $0.gesamt, $0.zeit) }
                if let v = vol {
                    Text("Volume (laut Dateisystem)").font(.subheadline).foregroundStyle(.secondary)
                    BelegungsBalken(belegt: v.belegt, gesamt: v.gesamt, stand: v.stand)
                    if let k = a.hw?.kapazitaet, v.gesamt > v.belegt, k.frei < v.gesamt - v.belegt {
                        Hinweis(symbol: "exclamationmark.triangle.fill", text: "Die Drobo hat physisch weniger Platz frei, als das Volume anzeigt. Maßgeblich ist der physische Wert: Die Drobo meldet dem Mac mehr Speicher, als die Festplatten tatsächlich fassen.")
                    }
                } else { Text("Die Belegung wird gelesen, sobald der Festplattenzugriff in Ordnung ist.").foregroundStyle(.secondary) }
                if let h = a.hw {
                    Zeile(name: "Modell", wert: h.modell.hasPrefix("Drobo") ? h.modell : "Drobo \(h.modell)")
                    Zeile(name: "Firmware", wert: h.firmware.isEmpty ? "–" : (h.firmware.split(separator: ",").first.map(String.init) ?? h.firmware) + (h.firmwareBuild.map { " (Build \($0))" } ?? ""))
                }
            }.padding(.top, 6)
        }
    }
}
