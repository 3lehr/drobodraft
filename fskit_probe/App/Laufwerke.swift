import DroboKern
import SwiftUI

/// Farbe + Wort (Farbe allein trägt keine Information).
extension SchachtFarbe {
    var wortText: String {
        switch self {
        case .aus: return String(localized: "Aus"); case .rot: return String(localized: "Rot"); case .gelb: return String(localized: "Gelb"); case .gruen: return String(localized: "Grün")
        case .rotGruen: return String(localized: "Rot/Grün"); case .rotGelb: return String(localized: "Rot/Gelb"); case .rotAus: return String(localized: "Rot/Aus")
        case .leer: return String(localized: "Leer"); case .unbekannt: return String(localized: "Unbekannt")
        }
    }
    var wort: LocalizedStringKey { LocalizedStringKey(wortText) }
    var farbe: Color {
        switch self { case .gruen: return .green; case .gelb, .rotGelb: return .orange; case .rot, .rotGruen, .rotAus: return .red; default: return .secondary }
    }
    var symbol: String {
        switch self { case .gruen: return "checkmark.circle.fill"; case .gelb, .rotGelb: return "exclamationmark.triangle.fill"; case .rot, .rotGruen, .rotAus: return "xmark.octagon.fill"; case .leer: return "circle.dashed"; default: return "circle" }
    }
}

struct LaufwerkeAnsicht: View {
    @EnvironmentObject var m: DroboModell

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Laufwerke").font(.largeTitle).accessibilityAddTraits(.isHeader)
                if let h = m.aktuell?.hw { Inhalt(h: h, netz: m.aktuell?.eintrag.netz != nil) } else { KeineDaten(netz: m.aktuell?.eintrag.netz != nil) }
            }.padding(20)
        }
    }

    struct KeineDaten: View {
        var netz = false
        var body: some View {
            if netz { Hinweis(symbol: "info.circle", text: "Noch keine Statusdaten von der DroboPro. Sie werden beim Start und über „Drobos suchen“ gelesen, nicht während sie eingehängt ist.", farbe: .blue) } else {
            Hinweis(symbol: "info.circle", text: "Keine Statusdaten der Drobo. Schächte, Schutzzustand und Warnungen kommen von einem optionalen Statustreiber (Systemerweiterung), der hier nicht aktiv ist oder noch keine Daten geliefert hat. Das Einhängen und alles andere funktioniert auch ohne.", farbe: .blue) }
        }
    }

    struct Inhalt: View {
        let h: DroboStatus
        var netz = false
        var body: some View {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                VStack(alignment: .leading, spacing: 14) {
                    zustand(ctx.date)
                    Karte(titel: "Gerät") {
                        Zeile(name: "Modell", wert: h.modell.hasPrefix("Drobo") ? h.modell : "Drobo \(h.modell)")
                        Zeile(name: "Firmware", wert: h.firmware.isEmpty ? "–" : (h.firmware.split(separator: ",").first.map(String.init) ?? h.firmware) + (h.firmwareBuild.map { " (Build \($0))" } ?? ""))
                        Zeile(name: "Aktualisiert", wert: alter(ctx.date))
                        if h.veraltet(jetzt: ctx.date) {
                            Hinweis(symbol: "clock.badge.exclamationmark", text: netz ? "Die Statusdaten sind nicht mehr aktuell. Sie werden nicht gelesen, solange die DroboPro eingehängt ist; „Drobos suchen“ liest sie neu." : "Die Statusdaten sind veraltet. Läuft der Statustreiber noch und ist die Drobo angeschlossen?")
                        }
                    }
                    if h.meldungen.contains(where: { $0.schwere != .ok }) {
                        Karte(titel: "Meldungen der Drobo") {
                            ForEach(Array(h.meldungen.filter { $0.schwere != .ok }.enumerated()), id: \.offset) { _, x in
                                Label { Text(LocalizedStringKey(x.text)) } icon: {
                                    Image(systemName: x.schwere == .kritisch ? "xmark.octagon.fill" : (x.schwere == .warnung ? "exclamationmark.triangle.fill" : "info.circle"))
                                        .foregroundStyle(x.schwere == .kritisch ? Color.red : (x.schwere == .warnung ? Color.orange : Color.secondary))
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if let k = h.kapazitaet {
                        Karte(titel: "Speicher (physisch)") {
                            BelegungsBalken(belegt: k.benutzt, gesamt: k.gesamtGeschuetzt, stand: nil, warnung: k.freiAnteil < 0.05 ? .red : (k.freiAnteil < 0.10 ? .orange : nil))
                            Zeile(name: "Frei", wert: "\(groesseText(k.frei)) (\(Int((k.freiAnteil * 100).rounded())) %)")
                            Text("Geschützter Speicher insgesamt: \(groesseText(k.gesamtGeschuetzt))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Karte(titel: "Schächte") {
                        ForEach(h.schaechte, id: \.nr) { s in SchachtZeile(s: s, mitFehler: !netz) }
                    }
                }
            }
        }

        @ViewBuilder func zustand(_ jetzt: Date) -> some View {
            let (wort, symbol, farbe): (LocalizedStringKey, String, Color) = h.schwere == .kritisch ? ("Zustand: kritisch", "xmark.octagon.fill", .red) : (h.schwere == .warnung ? ("Zustand: Warnung", "exclamationmark.triangle.fill", .orange) : ("Zustand: in Ordnung", "checkmark.circle.fill", .green))
            Label { Text(wort).font(.title3) } icon: { Image(systemName: symbol).foregroundStyle(farbe) }.accessibilityElement(children: .combine)
        }

        func alter(_ jetzt: Date) -> String {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
            return f.localizedString(for: h.zeit, relativeTo: jetzt)
        }
    }
}

struct SchachtZeile: View {
    let s: Schacht
    var mitFehler = true
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Schacht \(s.nr)").frame(width: 90, alignment: .leading).fontWeight(.semibold)
            Label { Text(s.farbe.wort) } icon: { Image(systemName: s.farbe.symbol).foregroundStyle(s.farbe.farbe) }.frame(width: 110, alignment: .leading)
            if s.belegt {
                Text(s.modell)
                Spacer(minLength: 8)
                Text(groesseText(s.kapazitaet)).monospacedDigit()
                if mitFehler { Text("Fehler: \(s.fehler)").foregroundStyle(s.fehler > 0 ? Color.red : Color.secondary) }
                if let t = s.temperatur { Text("Temperatur \(t)") }   // Einheit laut Recon nur Vermutung (offen: am Geraet gegen bekannten Wert eichen) -> ohne Einheit
            } else { Text("Kein Laufwerk").foregroundStyle(.secondary); Spacer() }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
