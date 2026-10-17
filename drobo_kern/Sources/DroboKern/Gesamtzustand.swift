import Foundation

/// Gesamtzustand einer Drobo fuer die Uebersicht: eine Stufe, eine Schlagzeile, genau eine Handlungsempfehlung, physischer Fuellstand.
/// Quellen: Status-Bits (Seite 09), Kapazitaet (02), Schwellen (30, sonst 85/95), Schachtlampen (03/35), letzte Dateisystempruefung.
/// Rein und ohne Zugriff aufs Geraet; die Oberflaeche uebersetzt die Faelle (Schluessel = Fall, nie ein fertiger Satz).
public enum Schlagzeile: Equatable {
    case inOrdnung, platzKnapp, platzSehrKnapp, plattenDefekt, keinePlatten, zuVieleFehlen, keineRedundanz, redundanzWirdHergestellt, dateisystemAuffaellig
    /// Weitere Meldung der Drobo (Katalogtext aus `statusTexte`), wenn keiner der Faelle oben passt.
    case meldung(String)
}

public enum Empfehlung: Equatable {
    case keine, schachtTauschen(Int), platteEinsetzen, platzSchaffen, abwarten, zustandPruefen, dateisystemPruefen
}

public enum Schutz: Equatable { case aktiv, keiner, wirdHergestellt }

public struct Gesamtzustand: Equatable {
    public var stufe: Schweregrad
    public var schlagzeile: Schlagzeile
    public var empfehlung: Empfehlung
    public var schutz: Schutz?
    /// Physisch belegt (gesamt geschuetzt - frei), 0...1; nil ohne Kapazitaetsseite.
    public var belegtAnteil: Double?
    /// Abgerundet, damit "95 %" auf dem Schirm genau dann dasteht, wenn die Schwelle erreicht ist.
    public var belegtProzent: Int? { belegtAnteil.map { Int(($0 * 100 + 1e-9).rounded(.down)) } }
    /// Blaue Fuellstands-LEDs wie am Geraet: je 10 % eine, ab > 0 % mindestens eine, hoechstens 10.
    public var ledAnzahl: Int { guard let a = belegtAnteil, a > 0 else { return 0 }; return min(10, max(1, Int((a * 10).rounded()))) }
    public var belegt: UInt64 = 0, frei: UInt64 = 0, reserviert: UInt64 = 0
}

public func gesamtzustand(_ st: DroboStatus, gelbProzent: Int = 85, rotProzent: Int = 95, pruefungOK: Bool? = nil) -> Gesamtzustand {
    var stufe = st.schwere
    var belegt: UInt64 = 0, frei: UInt64 = 0, reserviert: UInt64 = 0
    var anteil: Double?
    var platzRot = false, platzGelb = false
    if let k = st.kapazitaet, k.gesamtGeschuetzt > 0 {
        frei = min(k.frei, k.gesamtGeschuetzt); belegt = k.gesamtGeschuetzt - frei
        reserviert = k.gesamtUngeschuetzt > k.gesamtGeschuetzt ? k.gesamtUngeschuetzt - k.gesamtGeschuetzt : 0
        anteil = Double(belegt) / Double(k.gesamtGeschuetzt)
        // Ganzzahlig statt Double: Grenzwert (Schwelle) muss exakt greifen.
        platzRot = belegt * 100 >= UInt64(max(rotProzent, 0)) * k.gesamtGeschuetzt
        platzGelb = belegt * 100 >= UInt64(max(gelbProzent, 0)) * k.gesamtGeschuetzt
    }
    let bits = UInt64(st.statusBits ?? 0)
    platzRot = platzRot || bits & 0x2 != 0
    platzGelb = platzGelb || bits & 0x4 != 0
    if platzRot { stufe = max(stufe, .kritisch) } else if platzGelb { stufe = max(stufe, .warnung) }
    if pruefungOK == false { stufe = max(stufe, .warnung) }
    for sc in st.schaechte { stufe = max(stufe, schachtSchwere(sc.farbe)) }

    let rot = st.schaechte.first { [.rot, .rotAus].contains($0.farbe) }?.nr                 // 1 / 6: ausgefallen oder fehlt
    let verteilt = st.schaechte.first { $0.farbe == .rotGruen }?.nr, achtung = st.schaechte.first { $0.farbe == .rotGelb }?.nr   // 4 / 5 blinkend
    let gelb = st.schaechte.first { $0.farbe == .gelb }?.nr
    let schlagzeile: Schlagzeile, empfehlung: Empfehlung
    if bits & 0x8 != 0 { (schlagzeile, empfehlung) = (.keinePlatten, .platteEinsetzen) }
    else if bits & 0x10 != 0 || rot != nil { (schlagzeile, empfehlung) = (.plattenDefekt, rot.map { .schachtTauschen($0) } ?? .platteEinsetzen) }
    else if bits & 0x20 != 0 { (schlagzeile, empfehlung) = (.zuVieleFehlen, .platteEinsetzen) }
    else if platzRot { (schlagzeile, empfehlung) = (.platzSehrKnapp, gelb.map { .schachtTauschen($0) } ?? .platzSchaffen) }
    else if bits & 0x40 != 0 { (schlagzeile, empfehlung) = (.keineRedundanz, .platteEinsetzen) }
    else if verteilt != nil { (schlagzeile, empfehlung) = (.redundanzWirdHergestellt, .abwarten) }
    else if achtung != nil { (schlagzeile, empfehlung) = (.redundanzWirdHergestellt, .zustandPruefen) }
    else if bits & 0x200 != 0 { (schlagzeile, empfehlung) = (.redundanzWirdHergestellt, .abwarten) }
    else if platzGelb || gelb != nil { (schlagzeile, empfehlung) = (.platzKnapp, gelb.map { .schachtTauschen($0) } ?? .platzSchaffen) }
    else if let m = st.meldungen.first(where: { $0.schwere != .ok }) { (schlagzeile, empfehlung) = (.meldung(m.text), .keine) }
    else if pruefungOK == false { (schlagzeile, empfehlung) = (.dateisystemAuffaellig, .dateisystemPruefen) }
    else { (schlagzeile, empfehlung) = (.inOrdnung, .keine) }

    var schutz: Schutz?
    if st.statusBits != nil { schutz = bits & 0x40 != 0 ? .keiner : (bits & 0x200 != 0 ? .wirdHergestellt : .aktiv) }
    return Gesamtzustand(stufe: stufe, schlagzeile: schlagzeile, empfehlung: empfehlung, schutz: schutz, belegtAnteil: anteil, belegt: belegt, frei: frei, reserviert: reserviert)
}
