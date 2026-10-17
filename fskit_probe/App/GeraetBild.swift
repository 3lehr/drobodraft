import DroboKern
import SwiftUI

/// Gezeichnete Vorderansicht der Drobo: eigene SwiftUI-Formen, kein Logo und keine Grafik des Herstellers.
/// Schacht 1 oben (am Geraet geeicht 2026-10-16), Lampe je Schacht als Farbe + Symbol + Wort (WCAG 1.4.1), Fuellstandsleiste unten wie am Geraet.
/// VoiceOver: das Geraet ist ein Container, jeder Schacht ein eigenes Element; Tastaturfokus je Schacht (Button), Klick/Leertaste oeffnet die Einzelheiten.
/// Einbaulage der Platten: Eigenschaft des MODELLS (nicht der Schachtzahl allein).
/// gestapelt = waagerechte Einschuebe untereinander, Schacht 1 oben (Drobo 5C: am Geraet geeicht 2026-10-16).
/// nebeneinander = senkrechte Einschuebe, Schacht 1 links (DroboPro/8 Schaechte: ANNAHME nach Betreiberhinweis, OFFEN: am Geraet per Blinken eichen).
enum GeraeteLage {
    case gestapelt, nebeneinander
    static func von(modell: String, schaechte: Int) -> GeraeteLage {
        if modell.localizedCaseInsensitiveContains("pro") { return .nebeneinander }   // DroboPro, 8 Schaechte
        if modell.hasPrefix("5") { return .gestapelt }                                // Drobo 5C / 5D
        return schaechte > 5 ? .nebeneinander : .gestapelt                            // unbekanntes Modell: nach Schachtzahl
    }
}

struct DroboGeraet: View {
    let h: DroboStatus
    let g: Gesamtzustand
    var mitFehler = true
    @State private var offen: Int?

    /// 5 Schaechte (Drobo 5C) oder 8 (DroboPro); die Statusseite nennt die Zahl, sonst das Modell.
    var anzahl: Int { h.schaechte.isEmpty ? (h.modell.localizedCaseInsensitiveContains("pro") ? 8 : 5) : h.schaechte.count }

    var lage: GeraeteLage { .von(modell: h.modell, schaechte: anzahl) }

    var body: some View {
        VStack(spacing: 6) {
            if lage == .gestapelt {
                ForEach(1...anzahl, id: \.self) { n in
                    SchachtFeld(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: mitFehler, lage: lage, offen: $offen)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {   // Reihenfolge = Schachtnummer, auch fuer VoiceOver
                    ForEach(1...anzahl, id: \.self) { n in
                        SchachtFeld(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: mitFehler, lage: lage, offen: $offen)
                    }
                }
            }
            FuellLeiste(g: g).padding(.top, 4)
        }
        .padding(12)
        .frame(width: lage == .gestapelt ? 334 : CGFloat(anzahl) * 56 + 6 * CGFloat(anzahl - 1) + 24)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.3), lineWidth: 1))
        .environment(\.colorScheme, .dark)   // Geraet bleibt dunkel, auch im hellen Modus; Systemfarben passen sich an
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Drobo mit \(anzahl) Schächten"))
    }
}

/// Text zu einem Schacht fuer Tooltip und VoiceOver. Temperatur und Restlebensdauer ohne Einheit: laut Recon nur Vermutung (offen: am Geraet eichen).
func schachtBeschreibung(nr: Int, s: Schacht?, mitFehler: Bool) -> String {
    guard let s, s.belegt else {
        // kein Laufwerk erkannt, aber die Lampe kann trotzdem etwas melden (rot = fehlt/ausgefallen): nie hinter "leer" verstecken
        if let s, s.farbe != .leer { return String(localized: "Schacht \(nr)") + ", " + s.farbe.wortText }
        return String(localized: "Schacht \(nr), leer")
    }
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
    var lage: GeraeteLage = .gestapelt
    @Binding var offen: Int?
    var belegt: Bool { s?.belegt ?? false }
    var farbe: SchachtFarbe { s?.farbe ?? .leer }
    var kapText: String { belegt ? groesseText(s?.kapazitaet ?? 0) : String(localized: "Leer") }

    var body: some View {
        let beschreibung = schachtBeschreibung(nr: nr, s: s, mitFehler: mitFehler)
        Button { offen = nr } label: {
            if lage == .gestapelt {
                HStack(spacing: 8) {
                    Text("\(nr)").font(.callout.bold().monospacedDigit()).foregroundStyle(.white).frame(width: 16)
                    platte.frame(height: 30)
                    HStack(spacing: 4) {
                        Lampe(f: farbe)
                        Text(farbe.wortText).font(.caption).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    }.frame(width: 110, alignment: .leading)
                }
                .contentShape(Rectangle())
            } else {
                VStack(spacing: 4) {
                    Text("\(nr)").font(.callout.bold().monospacedDigit()).foregroundStyle(.white)
                    platte.frame(width: 44, height: 150).overlay(Text(kapText).font(.callout).monospacedDigit().foregroundStyle(.white).fixedSize().rotationEffect(.degrees(-90)))
                    Lampe(f: farbe)   // Spalte = Einschub = Lampe = Wort: alle auf derselben Mittelachse
                    Text(farbe.wortText).font(.caption2).foregroundStyle(.white).multilineTextAlignment(.center).frame(width: 56, height: 28, alignment: .top)
                }
                .frame(width: 56)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help(beschreibung)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(beschreibung)
        .accessibilityHint(String(localized: "Zeigt Einzelheiten zur Festplatte"))
        .popover(isPresented: Binding(get: { offen == nr }, set: { if !$0 { offen = nil } }), arrowEdge: .trailing) { SchachtDetail(nr: nr, s: s, mitFehler: mitFehler) }
    }
}

extension SchachtFeld {
    /// Einschub-Blende; im Stapel steht die Kapazitaet darin, bei senkrechten Einschueben legt der Aufrufer den gedrehten Text darueber.
    var platte: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(belegt ? 0.14 : 0.04))
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: belegt ? [] : [3, 3]))
            if lage == .gestapelt { Text(kapText).font(.callout).foregroundStyle(.white).monospacedDigit() }
        }
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
                // Netzwerk-Drobo (DroboPro): Seite 0x35 antwortet nie (Messbefund 2026-10-17) -> keine Zusatzfelder und kein Platzhalter, Zeilen entfallen
                if mitFehler && s.temperatur == nil && s.restleben == nil { Text("Die Drobo meldet für diese Festplatte keine Temperatur und keine Restlebensdauer.").font(.callout).foregroundStyle(.secondary) }
            } else { Text("Kein Laufwerk eingesetzt.").foregroundStyle(.secondary) }
        }.padding(14).frame(width: 300)
    }
}

/// Lampe eines Schachts: Symbol + Farbe; blinkende Codes (4/5/6) wechseln ~1 Hz zwischen zwei Farben, bei "Bewegung reduzieren" statisch geteilt. Das Wort steht immer daneben/darunter.
struct Lampe: View {
    let f: SchachtFarbe
    @Environment(\.accessibilityReduceMotion) private var wenig
    var body: some View {
        Group {
            if let (a, b) = f.blinkfarben {
                if wenig {
                    Image(systemName: f.symbol).foregroundStyle(LinearGradient(stops: [.init(color: a, location: 0), .init(color: a, location: 0.5), .init(color: b, location: 0.5), .init(color: b, location: 1)], startPoint: .leading, endPoint: .trailing))
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { t in Image(systemName: f.symbol).foregroundStyle(Int(t.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? a : b) }
                }
            } else { Image(systemName: f.symbol).foregroundStyle(f.farbe == .secondary ? Color.white.opacity(0.75) : f.farbe) }
        }
        .imageScale(.large).frame(width: 22, height: 22).accessibilityHidden(true)
    }
}

/// Blaue Fuellstands-LEDs wie am Geraet: zehn runde Punkte, je 10 % einer, ab > 0 % mindestens einer (Kern: `ledAnzahl`). VoiceOver: "Physisch belegt: N %".
struct FuellLeiste: View {
    let g: Gesamtzustand
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<10, id: \.self) { i in
                Circle().fill(i < g.ledAnzahl ? Color(red: 0.30, green: 0.64, blue: 1.0) : Color.white.opacity(0.18)).frame(width: 12, height: 12)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.belegtProzent.map { String(localized: "Physisch belegt: \($0) %") } ?? String(localized: "Füllstand unbekannt"))
    }
}
