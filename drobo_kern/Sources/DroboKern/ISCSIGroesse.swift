import Foundation

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Seiten, die vor und nach einer LUN-Groessenaenderung gelesen werden (alle mit exakter Laenge im Gate).
let lunGroesseSeiten: [UInt8] = [0x01, 0x02, 0x04, 0x07, 0x09]

func lunZustand(host: String, port: UInt16) throws -> [String] {
    let d = try ISCSISitzung(host: host, port: port); let ziele = try d.ziele(); d.abmelden()
    guard let z = ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    let s = try ISCSISitzung(host: host, port: port, ziel: z, zeitgrenze: 20); defer { s.abmelden() }
    var o = ["luns: \(try s.lunListe())"]
    for u in lunGroesseSeiten { o.append("3A/\(String(format: "%02x", u)): " + hex(try s.modeSense3A(lun: 0, unterseite: u))) }
    for l in try s.lunListe() {
        let k = try s.kapazitaet(lun: l)
        var z = "lun \(l): blocks \(k.bloecke) (\(k.bloecke * 512 >> 30) GiB)"
        if let p = try? GPT.ersteHFS(lies: { try s.lesen(lun: l, lba: $0, bloecke: $1) }), let vh = try? s.lesen(lun: l, lba: p.ersterLBA + 2, bloecke: 1) { z += ", HFS+ volume UUID \(hfsVolumeUUID(vh: vh) ?? "-")" } else { z += ", no HFS+" }
        o.append(z)
    }
    return o
}

/// LUN-Groesse der DroboPro aendern (Testgeraet). Vorher: kein iSCSI-Volume eingehaengt, Zustand (Seiten 01/02/04/07/09, LUNs) in `sicherungsordner` gesichert.
/// Ohne `ausfuehren` nur Trockenlauf. Danach: Antwort roh (Status/Sense/Fehler), Port 3260 alle 5 s bis `wartenMax`, Zustand erneut. Nichts wird gedeutet.
public func iscsiLunGroesse(host: String, port: UInt16 = 3260, tib: Int, ausfuehren zuschreiben: Bool, sicherungsordner: String, wartenMax: TimeInterval = 600,
                            eingehaengt: () -> [Int] = iscsiEingehaengteLuns, meldung: (String) -> Void) throws {
    guard (1...16).contains(tib) else { throw ISCSIFehler.verboten("LUN size \(tib) TiB outside 1...16") }
    let m = eingehaengt()
    guard m.isEmpty else { throw ISCSIFehler.verboten("iSCSI volumes are mounted (LUN \(m)): unmount all first") }
    let vorher = try lunZustand(host: host, port: port)
    let datei = sicherungsordner + "/lunsize-vorher-\(Int(Date().timeIntervalSince1970)).txt"
    try FileManager.default.createDirectory(atPath: sicherungsordner, withIntermediateDirectories: true)
    try vorher.joined(separator: "\n").write(toFile: datei, atomically: true, encoding: .utf8)
    vorher.forEach { meldung("before: " + $0) }
    meldung("state saved: \(datei)")
    guard zuschreiben else { meldung("dry run: would send EA 10 00 0F 00 01 21 00 04 00 with data \(String(format: "%08x", tib)) (\(tib) TiB). Add --execute."); return }
    let d = try ISCSISitzung(host: host, port: port); let ziele = try d.ziele(); d.abmelden()
    guard let z = ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    let s = try ISCSISitzung(host: host, port: port, ziel: z, zeitgrenze: 60)
    let t0 = Date()
    do {
        let a = try s.lunGroesseSetzen(tib: tib)
        meldung("EA 0F answered after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: status \(a.status), sense \(hex(a.sense)), data \(hex(a.daten))")
    } catch { meldung("EA 0F failed after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(error)") }
    s.abmelden()
    var weg: Date?, wieder: Date?
    while Date().timeIntervalSince(t0) < wartenMax {
        let ok = (try? ISCSISitzung(host: host, port: port).ziele()) != nil
        if !ok && weg == nil { weg = Date(); meldung("target unreachable after \(String(format: "%.0f", weg!.timeIntervalSince(t0))) s") }
        if ok && weg != nil && wieder == nil { wieder = Date(); meldung("target reachable again after \(String(format: "%.0f", wieder!.timeIntervalSince(t0))) s"); break }
        if ok && weg == nil && Date().timeIntervalSince(t0) > 30 { meldung("target stayed reachable (no restart seen in 30 s)"); break }
        Thread.sleep(forTimeInterval: 5)
    }
    if weg != nil && wieder == nil { meldung("STOP: target still unreachable after \(Int(wartenMax)) s"); return }
    for z in try lunZustand(host: host, port: port) { meldung("after: " + z) }
}
