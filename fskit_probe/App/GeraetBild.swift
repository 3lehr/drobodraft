import DroboKern
import SwiftUI

/// Gezeichnete Vorderansicht der Drobo: eigene SwiftUI-Formen, kein Logo und keine Grafik des Herstellers.
/// Schacht 1 oben (am Geraet geeicht 2026-10-16), Lampe je Schacht als Farbe + Symbol + Wort (WCAG 1.4.1), Fuellstandsleiste unten wie am Geraet.
/// VoiceOver: das Geraet ist ein Container, jeder Schacht ein eigenes Element; Tastaturfokus je Schacht (Button), Klick/Leertaste oeffnet die Einzelheiten.
struct DroboGeraet: View {
    let h: DroboStatus
    let g: Gesamtzustand
    var mitFehler = true
    @State private var offen: Int?

    /// 5 Schaechte (Drobo 5C) oder 8 (DroboPro); die Statusseite nennt die Zahl, sonst das Modell.
    var anzahl: Int { h.schaechte.isEmpty ? (h.modell.localizedCaseInsensitiveContains("pro") ? 8 : 5) : h.schaechte.count }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(1...anzahl, id: \.self) { n in
                SchachtFeld(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: mitFehler, offen: $offen)
            }
            FuellLeiste(anteil: g.belegtAnteil).padding(.top, 4)
        }
        .padding(12)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.3), lineWidth: 1))
        .environment(\.colorScheme, .dark)   // Geraet bleibt dunkel, auch im hellen Modus; Systemfarben passen sich an
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Drobo mit \(anzahl) Schächten"))
    }
}

/// Text zu einem Schacht fuer Tooltip und VoiceOver. Temperatur und Restlebensdauer ohne Einheit: laut Recon nur Vermutung (offen: am Geraet eichen).
func schachtBeschreibung(nr: Int, s: Schacht?, mitFehler: Bool) -> String {
    guard let s, s.belegt else { return String(localized: "Schacht \(nr), leer") }
    var t = [String(localized: "Schacht \(nr)"), s.farbe.wortText, groesseText(s.kapazitaet)]
    if !s.modell.isEmpty { t.append(s.modell) }
    if let x = s.temperatur { t.append(String(localized: "Temperatur \(x)")) }
    if let x = s.restleben { t.append(String(localized: "Restlebensdauer \(x)")) }
    if mitFehler { t.append(String(localized: "Fehler: \(s.fehler)")) }
    return t.joined(separator: ", ")
}

struct SchachtFeld: View {
    let nr: Int
    let s: Schacht?
    let mitFehler: Bool
    @Binding var offen: Int?
    var belegt: Bool { s?.belegt ?? false }

    var body: some View {
        let beschreibung = schachtBeschreibung(nr: nr, s: s, mitFehler: mitFehler)
        Button { offen = nr } label: {
            HStack(spacing: 8) {
                Text("\(nr)").font(.callout.bold().monospacedDigit()).foregroundStyle(.white).frame(width: 16)
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(belegt ? 0.14 : 0.04))
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: belegt ? [] : [3, 3]))
                    Text(belegt ? groesseText(s?.kapazitaet ?? 0) : String(localized: "Leer")).font(.callout).foregroundStyle(.white).monospacedDigit()
                }.frame(height: 30)
                HStack(spacing: 4) {
                    Image(systemName: (s?.farbe ?? .leer).symbol).foregroundStyle((s?.farbe ?? .leer).farbe == .secondary ? Color.white.opacity(0.75) : (s?.farbe ?? .leer).farbe)
                    Text((s?.farbe ?? .leer).wortText).font(.caption).foregroundStyle(.white)
                }.frame(width: 76, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(beschreibung)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(beschreibung)
        .accessibilityHint(String(localized: "Zeigt Einzelheiten zur Festplatte"))
        .popover(isPresented: Binding(get: { offen == nr }, set: { if !$0 { offen = nil } }), arrowEdge: .trailing) { SchachtDetail(nr: nr, s: s, mitFehler: mitFehler) }
    }
}

struct SchachtDetail: View {
    let nr: Int
    let s: Schacht?
    let mitFehler: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schacht \(nr)").font(.headline).accessibilityAddTraits(.isHeader)
            if let s, s.belegt {
                Zeile(name: "Lampe", wert: s.farbe.wortText)
                Zeile(name: "Kapazität", wert: groesseText(s.kapazitaet))
                if !s.modell.isEmpty { Zeile(name: "Modell", wert: s.modell) }
                // Einheit von Temperatur und Restlebensdauer unbelegt (Recon: Vermutung) -> Rohwert; offen: am Geraet gegen einen bekannten Wert eichen.
                if let t = s.temperatur { Zeile(name: "Temperatur (Rohwert)", wert: "\(t)") }
                if let r = s.restleben { Zeile(name: "Restlebensdauer (Rohwert)", wert: "\(r)") }
                if mitFehler { Zeile(name: "Fehler", wert: "\(s.fehler)") }
                if s.temperatur == nil && s.restleben == nil { Text("Die Drobo meldet für diese Festplatte keine Temperatur und keine Restlebensdauer.").font(.callout).foregroundStyle(.secondary) }
            } else { Text("Kein Laufwerk eingesetzt.").foregroundStyle(.secondary) }
        }.padding(14).frame(width: 300)
    }
}

/// Zehn blaue Segmente wie die Kapazitaetsanzeige am Geraet; der genaue Wert steht als Text daneben/darunter (Farbe traegt keine Information allein).
struct FuellLeiste: View {
    let anteil: Double?
    var gefuellt: Int { Int(((anteil ?? 0) * 10).rounded()) }
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(i < gefuellt ? Color(red: 0.30, green: 0.64, blue: 1.0) : Color.white.opacity(0.18)).frame(height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Füllstand"))
        .accessibilityValue(anteil.map { "\(Int(($0 * 100 + 1e-9).rounded(.down))) %" } ?? String(localized: "unbekannt"))
    }
}
