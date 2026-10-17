import Foundation
import IOKit

/// Status der Drobo, den der Dext (dext_probe) alle 60 s als Registry-Property "DroboStatus" ablegt (Rohantworten der MODE-SENSE-Seiten 0x3A,
/// siehe docs/DROBO_PROTOKOLL_RECON). Port von dext_probe/tools/drobo_decode.py; Felder ohne belegte Bedeutung bleiben roh (`unbelegt`).
public enum SchachtFarbe: Equatable { case aus, rot, gelb, gruen, rotGruen, rotGelb, rotAus, leer, unbekannt(UInt8) }

public struct Schacht: Equatable {
    public var nr: Int                 // 1-basiert (Schacht 1 oben)
    public var farbe: SchachtFarbe
    public var fehler: Int
    public var modell: String          // Hersteller/Modell aus dem Plattentext, ohne Seriennummer
    public var kapazitaet: UInt64      // Bytes
    public var temperatur: Int?        // nur wenn die Firmware einen Wert liefert (0 = nicht belegt)
    public var restleben: Int?         // nur SSD-Zaehler 0...100
    public var belegt: Bool { farbe != .leer && kapazitaet > 0 }
    public init(nr: Int, farbe: SchachtFarbe, fehler: Int, modell: String, kapazitaet: UInt64, temperatur: Int?, restleben: Int?) {
        self.nr = nr; self.farbe = farbe; self.fehler = fehler; self.modell = modell; self.kapazitaet = kapazitaet; self.temperatur = temperatur; self.restleben = restleben
    }
}

public struct DroboKapazitaet: Equatable {
    public var frei: UInt64, benutzt: UInt64, gesamtGeschuetzt: UInt64, gesamtUngeschuetzt: UInt64
    /// Anteil physisch frei am geschuetzten Gesamtwert (0...1).
    public var freiAnteil: Double { gesamtGeschuetzt == 0 ? 0 : Double(frei) / Double(gesamtGeschuetzt) }
    public init(frei: UInt64, benutzt: UInt64, gesamtGeschuetzt: UInt64, gesamtUngeschuetzt: UInt64) {
        self.frei = frei; self.benutzt = benutzt; self.gesamtGeschuetzt = gesamtGeschuetzt; self.gesamtUngeschuetzt = gesamtUngeschuetzt
    }
}

public enum Schweregrad: Int, Comparable { case ok = 0, warnung = 1, kritisch = 2
    public static func < (a: Schweregrad, b: Schweregrad) -> Bool { a.rawValue < b.rawValue } }

/// Statusmeldung: Schluessel ist der Katalogtext (de), die Oberflaeche uebersetzt ihn.
public struct Meldung: Equatable { public var bit: UInt64; public var text: String; public var schwere: Schweregrad
    public init(bit: UInt64, text: String, schwere: Schweregrad) { self.bit = bit; self.text = text; self.schwere = schwere } }

public struct DroboStatus: Equatable {
    public var zeit: Date
    public var ok: Bool
    public var fehler: String
    public var modell: String                  // z. B. "5C Gen3"
    public var firmware: String                // Version/Datum aus Seite 0x08, z. B. "Apr 16 2021, 00:19:56"
    public var firmwareBuild: Int?
    public var protokoll: String?              // "0.11"
    public var schaechte: [Schacht]
    public var kapazitaet: DroboKapazitaet?
    public var statusBits: UInt32?
    public var relayout: UInt32?
    public var meldungen: [Meldung]
    /// Schlimmster Grad: kritisch/warnung laut Masken des Dashboard-Dienstes, sonst ok (Schachtfarbe rot/gelb hebt mindestens auf warnung).
    public var schwere: Schweregrad
    /// Nicht gedeutete Werte (Seitenname -> Bytes), nichts wird erraten.
    public var unbelegt: [String: Data]

    public init(zeit: Date, ok: Bool, fehler: String, modell: String, firmware: String, firmwareBuild: Int?, protokoll: String?, schaechte: [Schacht], kapazitaet: DroboKapazitaet?,
                statusBits: UInt32?, relayout: UInt32?, meldungen: [Meldung], schwere: Schweregrad, unbelegt: [String: Data]) {
        self.zeit = zeit; self.ok = ok; self.fehler = fehler; self.modell = modell; self.firmware = firmware; self.firmwareBuild = firmwareBuild; self.protokoll = protokoll; self.schaechte = schaechte
        self.kapazitaet = kapazitaet; self.statusBits = statusBits; self.relayout = relayout; self.meldungen = meldungen; self.schwere = schwere; self.unbelegt = unbelegt
    }

    public func alter(jetzt: Date = Date()) -> TimeInterval { max(0, jetzt.timeIntervalSince(zeit)) }
    /// Der Dext liest alle 60 s; deutlich laenger her = Daten veraltet.
    public func veraltet(jetzt: Date = Date()) -> Bool { alter(jetzt: jetzt) > 150 }
}

private func u(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 { guard o + n <= b.count else { return 0 }; return b[o..<o + n].reduce(0) { $0 << 8 | UInt64($1) } }
private func s(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
    guard o < b.count else { return "" }
    let teil = Array(b[o..<min(o + n, b.count)]).prefix { $0 != 0 }
    return String(decoding: teil, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

func farbe(_ c: UInt8) -> SchachtFarbe {
    switch c { case 0: return .aus; case 1: return .rot; case 2: return .gelb; case 3: return .gruen; case 4: return .rotGruen; case 5: return .rotGelb; case 6: return .rotAus; case 0x80: return .leer; default: return .unbekannt(c) }
}

/// Maske kritisch / Warnung wie im Dashboard-Dienst (getSeverityForStatus).
let maskeKritisch: UInt64 = 0x14C4187A
let maskeWarnung: UInt64 = 0x36002300244

/// Klartext je Statusbit (Recon §2). Bits 0x80/0x100/0x400/0x2000/0x4000 stammen nur aus drobo-utils (am Geraet nicht belegt) und sind so gekennzeichnet.
let statusTexte: [(UInt64, String)] = [
    (0x2, "Speicherplatz sehr knapp (rote Schwelle erreicht)"), (0x4, "Speicherplatz wird knapp (gelbe Schwelle erreicht)"),
    (0x8, "Keine Festplatten eingesetzt"), (0x10, "Eine Festplatte ist defekt"), (0x20, "Zu viele Festplatten fehlen"),
    (0x40, "Keine Redundanz: ein Festplattenausfall würde Daten kosten"), (0x80, "Kein Reserve-Laufwerk (Hotspare)"), (0x100, "Kein Platz mehr"),
    (0x200, "Die Drobo stellt die Redundanz wieder her (Relayout läuft)"), (0x400, "Formatierung läuft"), (0x800, "Festplatten unterschiedlicher Größe gemischt"),
    (0x1000, "Unbekannte Firmware-Version"), (0x2000, "Neue Firmware installiert"), (0x4000, "Neues Volume nach dem Neustart"),
    (0x40000, "Inkompatibles Festplatten-Paket"), (0x10000000, "Unbekannter Zustand"),
]

public func decodiereDroboStatus(_ d: [String: Any]) -> DroboStatus? {
    func roh(_ k: String) -> [UInt8]? { (d[k] as? Data).map { [UInt8]($0) } }
    guard let zeit = (d["zeit"] as? NSNumber)?.doubleValue else { return nil }
    var unb: [String: Data] = [:]
    // INQUIRY: Produkt (16 Byte) = "5C\0\0Gen3\0\0\0\0B810": Teile durch NUL getrennt, die ersten beiden gelten als Modell
    var modell = ""
    if let q = roh("inquiry"), q.count >= 32 {
        let teile = q[16..<32].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        modell = teile.prefix(2).joined(separator: " ")
        if teile.count > 2 { unb["inquiry.produkt.rest"] = Data(teile.dropFirst(2).joined(separator: " ").utf8) }
    }
    var fw = "", build: Int?
    if let b = roh("p3A_08"), b.count >= 0x2A, b[0] == 0x7A, b[1] == 0x08 {
        fw = s(b, 0xA, 32); build = Int(u(b, 6, 2))
        unb["p3A_08.+0x2A..", default: Data()] = Data(b[0x2A..<min(b.count, 0x4A)])
    }
    var protokoll: String?; if let b = roh("p3A_06"), b.count >= 6 { protokoll = "\(b[4]).\(b[5])" }
    var kap: DroboKapazitaet?
    if let b = roh("p3A_02"), b.count >= 0x24, b[1] == 0x02 { kap = DroboKapazitaet(frei: u(b, 4, 8), benutzt: u(b, 0xC, 8), gesamtGeschuetzt: u(b, 0x14, 8), gesamtUngeschuetzt: u(b, 0x1C, 8)) }
    var bits: UInt32?, relayout: UInt32?
    if let b = roh("p3A_09"), b.count >= 0xC, b[1] == 0x09 { bits = UInt32(u(b, 4, 4)); relayout = UInt32(u(b, 8, 4)); unb["p3A_09.diskPackStatus"] = Data(b[0xC..<min(b.count, 0x10)]) }
    var schaechte: [Schacht] = []
    if let b = roh("p3A_35"), b.count >= 0xC, b[1] == 0x35 {
        let n = Int(b[8])
        for i in 0..<n {
            let o = 0xC + i * 0x6C
            guard o + 0x6C <= b.count else { break }
            let r = Array(b[o..<o + 0x6C])
            // str1 (+0xC, 44): Hersteller(8) + Modell(16) + Schnittstelle; Seriennummer (+0x44) wird absichtlich nicht gelesen
            let modellText = s(r, 0xC + 8, 16)
            let temp = Int(r[9]), leben = Int(r[0xA])
            schaechte.append(Schacht(nr: Int(r[0]) + 1, farbe: farbe(r[1]), fehler: Int(u(r, 2, 2)), modell: modellText, kapazitaet: u(r, 0x5C, 8),
                                     temperatur: temp > 0 ? temp : nil, restleben: (1...100).contains(leben) && r[8] != 0 ? leben : nil))
            unb["p3A_35.schacht\(i + 1).+0xB"] = Data([r[0xB]])
        }
    }
    var meld: [Meldung] = []; var schwere: Schweregrad = .ok
    if let st = bits {
        var rest = UInt64(st)
        for (bit, text) in statusTexte where rest & bit != 0 {
            let g: Schweregrad = maskeKritisch & bit != 0 ? .kritisch : (maskeWarnung & bit != 0 ? .warnung : .ok)
            meld.append(Meldung(bit: bit, text: text, schwere: g)); schwere = max(schwere, g); rest &= ~bit
        }
        if rest != 0 { meld.append(Meldung(bit: rest, text: "Weitere Meldung der Drobo", schwere: .ok)) }   // unbekannte Bits: kein Urteil
    }
    for sc in schaechte {
        switch sc.farbe { case .rot, .rotGelb, .rotGruen, .rotAus: schwere = max(schwere, .kritisch); case .gelb: schwere = max(schwere, .warnung); default: break }
    }
    return DroboStatus(zeit: Date(timeIntervalSince1970: zeit), ok: (d["ok"] as? Bool) ?? false, fehler: d["fehler"] as? String ?? "", modell: modell, firmware: fw,
                       firmwareBuild: build, protokoll: protokoll, schaechte: schaechte, kapazitaet: kap, statusBits: bits, relayout: relayout, meldungen: meld, schwere: schwere, unbelegt: unb)
}

/// Liest "DroboStatus" des Dext-Dienstes oberhalb des Blockgeraets `bsd` (z. B. "disk6s2"): IORegistry (Service-Ebene) vom Medium aufwaerts.
/// Nur IOKit, kein DiskArbitration: das sandboxed FSKit-Modul nutzt denselben Weg. nil = kein Dext/keine Daten.
public func liesDroboStatus(bsd: String) -> DroboStatus? {
    var cur = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
    guard cur != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(cur) }
    for _ in 0..<12 {
        if let p = IORegistryEntryCreateCFProperty(cur, "DroboStatus" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] { return decodiereDroboStatus(p) }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        IOObjectRelease(cur); cur = parent
    }
    return nil
}
