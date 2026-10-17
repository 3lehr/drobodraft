import Foundation

/// LUN-Verwaltung der DroboPro: Seiten 04 (LUNInfo) und 07 (LUNInfo2), gemessen 2026-10-17 an der echten DroboPro (Laenge genau 157, siehe `modeSenseExakt`).
/// Aufbau (gegen die Rohbytes geprueft): Kopf `7A <sub> <len16>` (die DroboPro antwortet auf Seite 07 mit Unterseite 0x04, deshalb wird nur 0x7A geprueft), dann 1 Byte Anzahl,
/// danach je Satz `u16 Satzlaenge (=17)` + Nutzdaten. 04: u8 LUN, u64 Groesse (Pool geschuetzt), u64 benutzt - nur der erste Satz ist gefuellt (Pool-Werte, gleich Seite 02), nicht je LUN.
/// 07: u8 LUN, u64 Groesse (16 TiB = 17592186044416), u8 Schema (3 = GPT, gelesen an LUN 0/1), u8 Partitionen, u8 Format-Kennung (0x40, unbelegt), u16 Kennung (1000/1001), 3 Rohbytes.
/// Saetze hinter der Anzahl sind Fuellung (LUN 2-7, Groesse 16 TiB, Schema 0) und werden nicht geliefert.

public struct LunSeite07: Equatable {
    public var lun: Int
    public var groesse: UInt64
    public var schema: UInt8          // 3 = GPT (an LUN 0/1 gegen die echte GPT geprueft), 0 = keins
    public var partitionen: Int
    public var format: UInt8          // unbelegt (0x40 an LUN 0/1)
    public var kennung: UInt16        // unbelegt (1000/1001)
    public var rest: [UInt8]          // 3 Rohbytes, unbelegt
    public var schemaText: String { schema == 3 ? "GPT" : (schema == 0 ? "-" : "0x" + String(schema, radix: 16)) }
}

private func be(_ b: [UInt8], _ o: Int, _ n: Int) -> UInt64 { b[o..<o + n].reduce(0) { $0 << 8 | UInt64($1) } }

/// nil = keine gueltige Seite. Pflicht: 0x7A, Anzahl <= 8, Satzlaenge 17 je Satz.
public func lunSeite07(_ b: [UInt8]) -> [LunSeite07]? {
    guard b.count >= 5, b[0] == 0x7A else { return nil }
    let n = Int(b[4]); guard n <= 8, b.count >= 5 + 19 * n else { return nil }
    var r: [LunSeite07] = []
    for i in 0..<n {
        let o = 5 + 19 * i
        guard be(b, o, 2) == 17 else { return nil }
        r.append(LunSeite07(lun: Int(b[o + 2]), groesse: be(b, o + 3, 8), schema: b[o + 11], partitionen: Int(b[o + 12]), format: b[o + 13], kennung: UInt16(be(b, o + 14, 2)), rest: Array(b[o + 16..<o + 19])))
    }
    return r
}

public struct LunSeite04: Equatable { public var lun: Int; public var gesamt: UInt64; public var benutzt: UInt64 }
public func lunSeite04(_ b: [UInt8]) -> [LunSeite04]? {
    guard b.count >= 5, b[0] == 0x7A else { return nil }
    let n = Int(b[4]); guard n <= 8, b.count >= 5 + 19 * n else { return nil }
    var r: [LunSeite04] = []
    for i in 0..<n {
        let o = 5 + 19 * i
        if b[o..<o + 19].allSatisfy({ $0 == 0 }) { continue }       // leerer Satz (gemessen: LUN 1 ist in Seite 04 ganz null)
        guard be(b, o, 2) == 17 else { return nil }
        let g = be(b, o + 3, 8), u = be(b, o + 11, 8)
        r.append(LunSeite04(lun: Int(b[o + 2]), gesamt: g, benutzt: u))
    }
    return r
}

public struct LunEintrag: Equatable {
    public init(lun: Int, groesse: UInt64, schema: String, partitionBytes: UInt64?, uuid: String?) { self.lun = lun; self.groesse = groesse; self.schema = schema; self.partitionBytes = partitionBytes; self.uuid = uuid }
    public var lun: Int
    public var groesse: UInt64          // READ CAPACITY, Bytes
    public var schema: String           // "GPT" / "-"
    public var partitionBytes: UInt64?  // erste HFS+-Partition
    public var uuid: String?            // Volume-UUID der HFS+-Partition
    public var hatDateisystem: Bool { uuid != nil }
}

/// Alle LUNs des Geraets: Liste aus REPORT LUNS, Groesse (READ CAPACITY), Schema (Seite 07, sonst aus der GPT), erste HFS+-Partition mit Volume-ID. Nur lesend.
public func netzLunVerzeichnis(sitzung s: ISCSISitzung) throws -> [LunEintrag] {
    let s07 = (try? s.modeSense3A(lun: 0, unterseite: 0x07)).flatMap(lunSeite07) ?? []
    return try s.lunListe().compactMap { l in
        guard let k = try? s.kapazitaet(lun: l), k.blockgroesse == 512 else { return nil }
        let teil = try? GPT.ersteHFS(lies: { try s.lesen(lun: l, lba: $0, bloecke: $1) })
        let vh = teil.flatMap { try? s.lesen(lun: l, lba: $0.ersterLBA + 2, bloecke: 1) }
        let schema = s07.first { $0.lun == l }?.schemaText ?? (teil != nil ? "GPT" : "-")
        return LunEintrag(lun: l, groesse: k.bloecke * 512, schema: schema, partitionBytes: teil.map { $0.bloecke * 512 }, uuid: vh.flatMap { hfsVolumeUUID(vh: $0) })
    }
}

/// Nach einem Format: die LUN neu einlesen (GPT, HFS+-Kopf, Volume-UUID). Die DroboPro braucht nach dem Schreiben einen Moment, darum bis zu `versuche` Anlaeufe im Abstand
/// `pause`; erst eine LUN MIT Dateisystem gilt. Ohne Erfolg wirft es (nie stilles Nichts: sonst blieb der LUN-Zustand der Ansicht unveraendert).
public func netzLunNachFormat(host: String, lun: Int, versuche: Int = 4, pause: TimeInterval = 3,
                              verzeichnis: (String) throws -> [LunEintrag] = { try netzLunVerzeichnis(host: $0) }) throws -> (alle: [LunEintrag], neu: LunEintrag) {
    var letzter: Error = ISCSIFehler.protokoll("LUN \(lun) has no file system after formatting")
    for i in 0..<max(versuche, 1) {
        if i > 0 { Thread.sleep(forTimeInterval: pause) }
        do { let l = try verzeichnis(host); if let e = l.first(where: { $0.lun == lun }), e.hatDateisystem { return (l, e) } }
        catch { letzter = error }
    }
    throw letzter
}

/// Eintrag der LUN im gespeicherten Ziel nach dem Format: neue Volume-UUID und neuer Name (die Freigabe fuer die neue UUID setzt das Einhaengen).
public func netzZielNachFormat(_ nz: NetzZiel, lun: Int, uuid: String, name: String) -> NetzZiel {
    var n = nz
    var l = (nz.luns ?? []).filter { $0.lun != lun }; l.append(NetzLunEintrag(lun: lun, uuid: uuid, name: name)); n.luns = l.sorted { $0.lun < $1.lun }
    return n
}

public func netzLunVerzeichnis(host: String) throws -> [LunEintrag] {
    let s = try netzSitzung(host: host); defer { s.abmelden() }
    return try netzLunVerzeichnis(sitzung: s)
}
