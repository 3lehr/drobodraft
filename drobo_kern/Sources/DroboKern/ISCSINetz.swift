import Foundation

/// Netzwerk-Drobo (DroboPro per iSCSI) fuer die App: entdecken, Status lesen, einhaengen mit Metadaten-Sicherung. Alle Wege laufen ueber den Hilfsdienst
/// (Weiterleitung auf 127.0.0.1, siehe HelferLogik.swift); die Funktionen mit `sitzung:` sind rein und gegen das Python-Ziel getestet.

public struct NetzLun: Equatable { public var lun: Int; public var uuid: String; public var partitionBytes: UInt64 }
public struct NetzInfo: Equatable { public var name: String; public var gelbProzent: Int; public var rotProzent: Int
    public init(name: String, gelbProzent: Int, rotProzent: Int) { self.name = name; self.gelbProzent = gelbProzent; self.rotProzent = rotProzent } }

public func iscsiOrt(_ lun: Int) -> String { "\(iscsiVorgabeOrt)\(lun)" }

/// Aktuelle Einhaengung dieser LUN (Mount-Tabelle), nil = nicht eingehaengt.
public func netzEinhaengung(lun: Int) -> Einhaengung? { einhaengungen().values.first { $0.ort == iscsiOrt(lun) || $0.ort == "/private" + iscsiOrt(lun) } }

/// Lesequelle auf die Partition einer LUN (Offsets ab Partitionsanfang, 512-B-Sektoren, nie ueber das Partitionsende).
func partitionLeser(_ s: ISCSISitzung, lun: Int, partition p: GPT.Partition) -> (UInt64, Int) throws -> [UInt8] {
    let laenge = p.bloecke * 512
    return { off, n in
        guard off < laenge, n > 0 else { return [] }
        let m = Int(min(UInt64(n), laenge - off)), a = off / 512
        let d = try s.lesen(lun: lun, lba: p.ersterLBA + a, bloecke: Int((off + UInt64(m) + 511) / 512 - a))
        return Array(d[Int(off - a * 512)..<Int(off - a * 512) + m])
    }
}

/// Sitzung ueber die Weiterleitung des Dienstes (erstes Ziel des Geraets).
func netzSitzung(host: String, zeitgrenze: TimeInterval = 15) throws -> ISCSISitzung {
    let port = try helferISCSIWeiterleitung(host: host)
    let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: zeitgrenze, ersteZeitgrenze: ISCSISitzung.ersteZeitgrenzeNetz); let ziele = try d.ziele(); d.abmelden()
    guard let z = ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    return try ISCSISitzung(host: "127.0.0.1", port: port, ziel: z, zeitgrenze: zeitgrenze, ersteZeitgrenze: ISCSISitzung.ersteZeitgrenzeNetz)
}

/// LUNs mit gueltiger GPT, HFS+-Partition und Volume-ID.
public func netzLuns(sitzung s: ISCSISitzung) throws -> [NetzLun] {
    try s.lunListe().compactMap { l in
        guard let k = try? s.kapazitaet(lun: l), k.blockgroesse == 512,
              let p = try? GPT.ersteHFS(lies: { try s.lesen(lun: l, lba: $0, bloecke: $1) }),
              let vh = try? s.lesen(lun: l, lba: p.ersterLBA + 2, bloecke: 1), let u = hfsVolumeUUID(vh: vh) else { return nil }
        return NetzLun(lun: l, uuid: u, partitionBytes: p.bloecke * 512)
    }
}

public func netzEntdecken(host: String) throws -> [NetzLun] {
    let s = try netzSitzung(host: host); defer { s.abmelden() }
    return try netzLuns(sitzung: s)
}

/// DroboPro-Schaechte aus Seite 0x03 (72 B je Satz ab Byte 5: u16, u8 Slot, u64 Kapazitaet, u64, u8 LED-Code, char[32] Modell, char[16], u32; gegen das Geraet gelesen,
/// Seriennummern stehen nicht darin und werden nicht gelesen).
func droboProSchaechte(_ b: [UInt8]) -> [Schacht] {
    guard b.count >= 5, b[0] == 0x7A, b[1] == 0x03 else { return [] }
    return (0..<Int(b[4])).compactMap { i in
        let o = 5 + 72 * i
        guard o + 72 <= b.count else { return nil }
        let kap = b[o + 3..<o + 11].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let modell = String(decoding: b[o + 20..<o + 52].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return Schacht(nr: Int(b[o + 2]) + 1, farbe: farbe(b[o + 19]), fehler: 0, modell: modell, kapazitaet: kap, temperatur: nil, restleben: nil)
    }
}

/// Status der DroboPro aus den Seiten 02, 06, 08, 09 (vorhandener Decoder) plus 03 (Schaechte), 05 (Name), 30 (Schwellen gelb/rot in Prozent).
public func netzStatus(sitzung s: ISCSISitzung) throws -> (DroboStatus, NetzInfo) {
    var d: [String: Any] = ["zeit": NSNumber(value: Date().timeIntervalSince1970), "ok": true, "fehler": "keine"]
    d["inquiry"] = Data(try s.inquiry(lun: 0))
    for (n, k) in [(UInt8(0x06), "p3A_06"), (0x02, "p3A_02"), (0x08, "p3A_08"), (0x09, "p3A_09")] { d[k] = Data(try s.modeSense3A(lun: 0, unterseite: n)) }
    guard var st = decodiereDroboStatus(d) else { throw ISCSIFehler.protokoll("status pages not decodable") }
    st.modell = st.modell.trimmingCharacters(in: .whitespaces)
    st.schaechte = droboProSchaechte(try s.modeSense3A(lun: 0, unterseite: 0x03))
    for sc in st.schaechte { st.schwere = max(st.schwere, schachtSchwere(sc.farbe)) }
    let n = try s.modeSense3A(lun: 0, unterseite: 0x05), o = try s.modeSense3A(lun: 0, unterseite: 0x30)
    let name = n.count >= 12 && n[1] == 0x05 ? String(decoding: n[10..<min(n.count, 42)].prefix { $0 != 0 }, as: UTF8.self) : ""
    let info = NetzInfo(name: name, gelbProzent: o.count >= 6 && o[1] == 0x30 ? Int(o[4]) : 85, rotProzent: o.count >= 6 && o[1] == 0x30 ? Int(o[5]) : 95)
    return (st, info)
}

public func netzStatusLesen(host: String) throws -> (DroboStatus, NetzInfo) {
    let s = try netzSitzung(host: host, zeitgrenze: 10); defer { s.abmelden() }
    return try netzStatus(sitzung: s)
}

/// Metadaten-Sicherung der HFS+-Partition einer LUN (gleiches Format wie bei der 5C); Ort wird wie dort geprueft (nie Systemplatte).
@discardableResult
func netzSicherung(sitzung s: ISCSISitzung, lun: Int, partition p: GPT.Partition, uuid: String, ort: String, anzahl: Int) throws -> SicherungsErgebnis {
    try sicherungsOrtPruefen(ort, quelle: nil)
    let l = try HFSLeser(name: "iSCSI LUN \(lun)", lesen: partitionLeser(s, lun: lun, partition: p))
    return try metadatenSichern(leser: l, quelle: "iscsi-lun\(lun)", ort: ort, uuid: uuid, anzahl: anzahl, partitionsgroesse: p.bloecke * 512)
}
