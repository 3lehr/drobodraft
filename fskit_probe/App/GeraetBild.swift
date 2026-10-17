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
    var betrieb: Betrieb = .aus
    @State private var offen: Int?

    /// 5 Schaechte (Drobo 5C) oder 8 (DroboPro); die Statusseite nennt die Zahl, sonst das Modell.
    var anzahl: Int { h.schaechte.isEmpty ? (h.modell.localizedCaseInsensitiveContains("pro") ? 8 : 5) : h.schaechte.count }

    var lage: GeraeteLage { .von(modell: h.modell, schaechte: anzahl) }

    var body: some View {
        VStack(spacing: Abstand.s) {
            if lage == .gestapelt {
                ForEach(1...anzahl, id: \.self) { n in
                    SchachtFeld(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: mitFehler, lage: lage, offen: $offen)
                }
            } else {
                HStack(alignment: .top, spacing: Mass.schachtLuecke) {   // Reihenfolge = Schachtnummer, auch fuer VoiceOver
                    ForEach(1...anzahl, id: \.self) { n in
                        SchachtFeld(nr: n, s: h.schaechte.first { $0.nr == n }, mitFehler: mitFehler, lage: lage, offen: $offen)
                    }
                    VStack(spacing: Abstand.m) {   // rechts: Fuellstand senkrecht, darunter die Betriebslampe
                        FuellLeiste(g: g, senkrecht: true).padding(.top, Abstand.l)
                        BetriebsLampe(b: betrieb)
                    }.frame(width: Mass.ledSpalte)
                }
            }
            if lage == .gestapelt { FuellLeiste(g: g).padding(.top, Abstand.xs) }
        }
        .padding(Abstand.m)
        .frame(width: lage == .gestapelt ? Mass.geraetStapelBreite : CGFloat(anzahl) * (Mass.schachtBreite + Mass.schachtLuecke) + Mass.ledSpalte + Mass.geraetRand)
        .background(RoundedRectangle(cornerRadius: Radius.geraet).fill(Farbe.geraetGehaeuse))
        .overlay(RoundedRectangle(cornerRadius: Radius.geraet).stroke(Color.white.opacity(0.3), lineWidth: 1))
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
                HStack(spacing: Abstand.s) {
                    Text("\(nr)").font(.callout.bold().monospacedDigit()).foregroundStyle(.white).frame(width: Mass.schachtNummerBreite)
                    platte.frame(height: Mass.plateStapelHoehe)
                    HStack(spacing: Abstand.xs) {
                        Lampe(f: farbe)
                        Text(farbe.wortText).font(.caption).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    }.frame(minWidth: Mass.lampeText, alignment: .leading)
                }
                .contentShape(Rectangle())
            } else {
                VStack(spacing: Abstand.xs) {
                    Text("\(nr)").font(.callout.bold().monospacedDigit()).foregroundStyle(.white)
                    platte.frame(width: Mass.plateSenkrechtBreite, height: Mass.plateSenkrechtHoehe).overlay(Text(kapText).font(.callout).monospacedDigit().foregroundStyle(.white).fixedSize().rotationEffect(.degrees(-90)))
                    Lampe(f: farbe)   // Spalte = Einschub = Lampe = Wort: alle auf derselben Mittelachse
                    Text(farbe.wortText).font(.caption2).foregroundStyle(.white).multilineTextAlignment(.center).frame(width: Mass.schachtBreite, height: Mass.lampeWortHoehe, alignment: .top)
                }
                .frame(width: Mass.schachtBreite)
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
            RoundedRectangle(cornerRadius: Radius.platte).fill(Color.white.opacity(belegt ? 0.14 : 0.04))
            RoundedRectangle(cornerRadius: Radius.platte).strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: belegt ? [] : [3, 3]))
            if lage == .gestapelt { Text(kapText).font(.callout).foregroundStyle(.white).monospacedDigit() }
        }
    }
}

struct SchachtDetail: View {
    let nr: Int
    let s: Schacht?
    let mitFehler: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Abstand.s) {
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
        }.padding().frame(minWidth: Mass.popoverMin, idealWidth: Mass.popover)
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
        .imageScale(.large).frame(width: Mass.lampe, height: Mass.lampe).accessibilityHidden(true)
    }
}

/// Betriebslampe (nur DroboPro-Bild): Farbe NICHT vom Geraet gelesen (keine Statusseite bekannt; unbekannte Seiten wie 0x36 werden nicht abgefragt, sie haengen die DroboPro).
/// Abgeleitet aus Sitzung und Status: Ein = erreichbar und Status gelesen, Aus = nicht erreichbar, Reagiert nicht = Bremse "reagiert nicht".
enum Betrieb {
    case ein, aus, haengt
    var wort: String { switch self { case .ein: return String(localized: "Ein"); case .aus: return String(localized: "Aus oder nicht erreichbar"); case .haengt: return String(localized: "Reagiert nicht") } }
    var symbol: String { switch self { case .ein: return "power.circle.fill"; case .aus: return "power.circle"; case .haengt: return "exclamationmark.octagon.fill" } }
    var farbe: Color { switch self { case .ein: return .green; case .aus: return .secondary; case .haengt: return .red } }
}

struct BetriebsLampe: View {
    let b: Betrieb
    var body: some View {
        VStack(spacing: Abstand.xs) {
            Image(systemName: b.symbol).foregroundStyle(b.farbe).font(.title2).accessibilityHidden(true)
            Text(b.wort).font(.caption2).foregroundStyle(.white).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Mass.ledSpalte)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Betrieb: \(b.wort)"))
    }
}

/// Blaue Fuellstands-LEDs wie am Geraet: zehn runde Punkte, je 10 % einer, ab > 0 % mindestens einer (Kern: `ledAnzahl`). VoiceOver: "Physisch belegt: N %".
/// Waagerechte Reihe (5C) oder senkrechte Spalte (DroboPro, rechts neben den Schaechten, fuellt von UNTEN nach OBEN: Annahme, am Geraet UNGEEICHT).
struct FuellLeiste: View {
    let g: Gesamtzustand
    var senkrecht = false
    @ScaledMetric(relativeTo: .caption) private var punkt = Mass.ledPunkt
    @ScaledMetric(relativeTo: .caption) private var punktSenkrecht = Mass.ledPunktSenkrecht

    func led(_ i: Int, _ d: CGFloat) -> some View {
        Circle().fill(i < g.ledAnzahl ? Farbe.fuellLed : Color.white.opacity(0.18)).frame(width: d, height: d)
    }

    var body: some View {
        Group {
            if senkrecht {
                VStack(spacing: Mass.ledLuecke) { ForEach((0..<10).reversed(), id: \.self) { led($0, punktSenkrecht) } }   // oberste LED = Nummer 10
            } else {
                HStack(spacing: Abstand.s) { ForEach(0..<10, id: \.self) { led($0, punkt) } }.frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(g.belegtProzent.map { String(localized: "Physisch belegt: \($0) %") } ?? String(localized: "Füllstand unbekannt"))
    }
}
