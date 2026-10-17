import Foundation

/// SCSI ueber iSCSI: nur Befehle auf der Allowlist. Alles andere (v.a. 0xEA, MODE SELECT 0x15/0x55, 0xE1/0xE2, FORMAT, UNMAP, WRITE SAME ...)
/// wirft `.verboten`, BEVOR ein Byte gesendet wird. Es gibt genau einen Sendeweg (`befehl`), das Gate steht davor.
public struct SCSIAntwort { public var status: UInt8; public var daten: [UInt8]; public var sense: [UInt8] }

extension ISCSISitzung {
    /// Seiten 0x3A, die bei der DroboPro gemessen antworten (33 ohne Antwort an der DroboPro, aber lesend ungefaehrlich -> erlaubt, mit Zeitgrenze; 35 siehe unten: verboten).
    public static let modeSenseUnterseiten: Set<UInt8> = [0x01, 0x02, 0x06, 0x08, 0x09, 0x33]
    /// Seiten, die die DroboPro NUR mit genau passender Allokationslaenge beantwortet (gemessen: 04/07 bei 512 keine Antwort, bei 157 ja; Laengen aus drobo-utils/Recon).
    public static let modeSenseExakt: [UInt8: Int] = [0x03: 0x360, 0x04: 0x9D, 0x05: 0x2A, 0x07: 0x9D, 0x30: 0x0D]
    /// Seite 0x35 (SlotInfo2) wird NIE gesendet: Messbefund 2026-10-17, die DroboPro antwortet bei keiner Allokationslaenge (4, 8, 864, 868, 869, 872, 876 -> keine Antwort,
    /// "iSCSI timeout: no data within 10.0 s"). Diese Sitzung gibt es nur fuer die DroboPro; Seite 03 (864) liefert Schaechte, Temperatur/Restleben gibt es dort nicht.
    /// Allokationslaenge 4096 beantwortet die DroboPro nicht (Sitzung haengt) -> Gate begrenzt auf 512.
    public static let modeSenseMax = 512

    /// nil = erlaubt, sonst der Ablehnungsgrund. Rein, ohne Netz; das Gate ruft diese Funktion auf.
    public static func verbot(cdb: [UInt8], schreiben: Int, lesen: Int) -> String? {
        guard let op = cdb.first else { return "empty CDB" }
        let hex = String(format: "0x%02x", op)
        func laenge(_ n: Int) -> String? { cdb.count == n ? nil : "\(hex): CDB length \(cdb.count), expected \(n)" }
        if op == 0xEA { return lunGroesseVerbot(cdb: cdb, schreiben: schreiben, lesen: lesen) }
        if op != 0x8A && schreiben != 0 { return "\(hex): data-out only allowed for WRITE(16)" }
        if op == 0x8A && lesen != 0 { return "WRITE(16) with read length" }
        switch op {
        case 0x00, 0x12: if let f = laenge(6) { return f }
        case 0xA0: if let f = laenge(12) { return f }
        case 0x9E:
            if let f = laenge(16) { return f }
            if cdb[1] & 0x1f != 0x10 { return "0x9e: only READ CAPACITY(16) (service action 0x10)" }
        case 0x88, 0x8A:
            if let f = laenge(16) { return f }
            if cdb[1] & 0xE0 != 0 || cdb[14] & 0x3F != 0 { return "\(hex): protect/group bits not allowed" }
            let n = Int(cdb[10]) << 24 | Int(cdb[11]) << 16 | Int(cdb[12]) << 8 | Int(cdb[13])
            if n == 0 { return "\(hex): zero transfer length" }
            if op == 0x8A && schreiben > maxDatenmenge { return "WRITE(16) of \(schreiben) bytes exceeds \(maxDatenmenge)" }
            if op == 0x88 && lesen > maxDatenmenge { return "READ(16) of \(lesen) bytes exceeds \(maxDatenmenge)" }
        case 0x5A:
            if let f = laenge(10) { return f }
            let al = Int(cdb[7]) << 8 | Int(cdb[8])
            if cdb[2] == 0x3A, let genau = modeSenseExakt[cdb[3]] { return al == genau ? nil : "0x5a: sub-page \(cdb[3]) needs allocation length exactly \(genau)" }
            if cdb[2] != 0x3A || !modeSenseUnterseiten.contains(cdb[3]) { return "0x5a: only page 0x3A, sub-pages \(modeSenseUnterseiten.union(modeSenseExakt.keys).sorted())" }
            if al > modeSenseMax { return "0x5a: allocation length above \(modeSenseMax) is not answered by the DroboPro" }
        default: return "opcode \(hex) is not on the allowlist"
        }
        return nil
    }

    /// EINZIGER erlaubter EA-Befehl: LUN-Groesse setzen, `EA 10 00 0F 00 <txn> 21 00 04 00` mit genau 4 Datenbytes (TiB, BE). Alles andere aus der 0xEA-Familie
    /// (Format 0x02, Neustart, Ausschalten, Firmware ...) bleibt verboten. Die Daten MUESSEN im Command-PDU mitgehen (sonst startet die DroboPro neu, gemessen) -
    /// das erzwingt `befehl` ueber `immediateAusgehandelt`. Nur diese iSCSI-Sitzung kann EA senden; der USB-/Dext-Weg hat keinen Sendeweg dafuer.
    static func lunGroesseVerbot(cdb: [UInt8], schreiben: Int, lesen: Int) -> String? {
        guard cdb.count == 10 else { return "0xea: CDB length \(cdb.count), expected 10" }
        guard cdb[1] == 0x10, cdb[2] == 0x00, cdb[3] == 0x0F, cdb[4] == 0x00, cdb[6] == 0x21, cdb[7] == 0x00, cdb[8] == 0x04, cdb[9] == 0x00 else { return "0xea: only the LUN size command (EA 10 00 0F 00 txn 21 00 04 00) is allowed" }
        guard schreiben == 4, lesen == 0 else { return "0xea: LUN size command carries exactly 4 data bytes" }
        return nil
    }

    /// Einziger Sendeweg. `daten` nur bei WRITE(16); `lesen` = erwartete Datenmenge von Ziel zu Initiator.
    public func befehl(lun: Int, cdb: [UInt8], lesen: Int = 0, daten: [UInt8] = []) throws -> SCSIAntwort {
        if let grund = Self.verbot(cdb: cdb, schreiben: daten.count, lesen: lesen) { throw ISCSIFehler.verboten(grund) }
        // DroboPro-Neustart durch WRITE ohne Immediate-Daten (Messbefund in ISCSI.swift): ohne ausgehandeltes ImmediateData=Yes wird nie ein WRITE gesendet.
        if cdb.first == 0xEA && !lunGroesseFreigabe { throw ISCSIFehler.verboten("EA refused: LUN size changes are not enabled on this session") }
        if (cdb.first == 0x8A || cdb.first == 0xEA) && !immediateAusgehandelt { throw ISCSIFehler.verboten("WRITE refused: target did not negotiate ImmediateData=Yes") }
        if discovery { throw ISCSIFehler.verboten("discovery session cannot carry SCSI commands") }
        return try gesichert { try austausch(lun: lun, cdb: cdb, lesen: lesen, daten: daten) }
    }

    private func austausch(lun: Int, cdb: [UInt8], lesen: Int, daten: [UInt8]) throws -> SCSIAntwort {
        let id = naechsteITT(), c = cmdSN, st = expStatSN
        let erwartet = daten.isEmpty ? lesen : daten.count
        let flags: UInt8 = daten.isEmpty ? (lesen > 0 ? 0xC1 : 0x81) : 0xA1
        var cdb16 = cdb + [UInt8](repeating: 0, count: 16 - cdb.count)
        cdb16 = Array(cdb16.prefix(16))
        let sofort = daten.isEmpty ? 0 : min(daten.count, firstBurst, zielSegment)      // erster Datenteil im Command-PDU, Rest per R2T
        try draht.senden(pdu(0x01, flags, daten: Array(daten.prefix(sofort))) { h in
            h[9] = UInt8(lun & 0xff); h[8] = UInt8(lun >> 8 & 0x3f)
            put32(&h, 16, id); put32(&h, 20, UInt32(erwartet)); put32(&h, 24, c); put32(&h, 28, st); h[32..<48] = cdb16[...]
        })
        cmdSN &+= 1
        var puffer = [UInt8](repeating: 0, count: lesen), ende = 0, gesendet = 0
        while true {
            let r = try empfangen()
            switch r.op {
            case 0x25:      // Data-In
                let off = Int(r.u32(40))
                guard off >= 0, off + r.daten.count <= puffer.count else { throw ISCSIFehler.protokoll("Data-In beyond expected length") }
                puffer.replaceSubrange(off..<off + r.daten.count, with: r.daten); ende = max(ende, off + r.daten.count)
                if r.bhs[1] & 0x01 != 0 { expStatSN = r.u32(24) &+ 1; return SCSIAntwort(status: r.bhs[3], daten: Array(puffer[0..<ende]), sense: []) }
            case 0x21:      // SCSI Response
                expStatSN = r.u32(24) &+ 1
                guard r.bhs[2] == 0 else { throw ISCSIFehler.protokoll("target reported iSCSI response \(r.bhs[2])") }
                var sense: [UInt8] = []
                if r.daten.count >= 2 { let n = Int(r.daten[0]) << 8 | Int(r.daten[1]); sense = Array(r.daten.dropFirst(2).prefix(n)) }
                return SCSIAntwort(status: r.bhs[3], daten: Array(puffer[0..<ende]), sense: sense)
            case 0x31:      // R2T
                let ttt = r.u32(20), off = Int(r.u32(40)), n = Int(r.u32(44))
                guard !daten.isEmpty, n > 0, off >= 0, off + n <= daten.count, n <= maxBurst else { throw ISCSIFehler.protokoll("invalid R2T offset \(off) length \(n)") }
                try datenSenden(lun: lun, itt: id, ttt: ttt, ab: off, daten: daten[off..<off + n])
                gesendet += n
            case 0x20:      // NOP-In: nur Pings (TTT != reserviert) beantworten
                let ttt = r.u32(20)
                if ttt != 0xffff_ffff {
                    let c = cmdSN, st = expStatSN
                    try draht.senden(pdu(0x40, 0x80) { h in put32(&h, 16, 0xffff_ffff); put32(&h, 20, ttt); put32(&h, 24, c); put32(&h, 28, st) })
                }
            case 0x32: break    // Async Message: ignoriert (ErrorRecoveryLevel 0)
            default: throw ISCSIFehler.protokoll("unexpected opcode 0x\(String(r.op, radix: 16))")
            }
        }
    }

    /// Data-Out-Folge fuer eine R2T: Stuecke <= MaxRecvDataSegmentLength des Ziels, F-Bit am letzten, DataSN ab 0.
    private func datenSenden(lun: Int, itt: UInt32, ttt: UInt32, ab: Int, daten: ArraySlice<UInt8>) throws {
        var sn: UInt32 = 0, pos = daten.startIndex
        while pos < daten.endIndex {
            let ende = min(pos + zielSegment, daten.endIndex), st = expStatSN, snNow = sn
            try draht.senden(pdu(0x05, ende == daten.endIndex ? 0x80 : 0, daten: Array(daten[pos..<ende])) { h in
                h[9] = UInt8(lun & 0xff); h[8] = UInt8(lun >> 8 & 0x3f)
                put32(&h, 16, itt); put32(&h, 20, ttt); put32(&h, 28, st); put32(&h, 36, snNow); put32(&h, 40, UInt32(ab + pos - daten.startIndex))
            })
            sn += 1; pos = ende
        }
    }

    // MARK: Komfortbefehle

    private func gut(_ a: SCSIAntwort) throws -> [UInt8] {
        if a.status != 0 { throw ISCSIFehler.scsi(status: a.status, sense: a.sense) }
        return a.daten
    }

    public func testUnitReady(lun: Int) throws { _ = try gut(befehl(lun: lun, cdb: [0, 0, 0, 0, 0, 0])) }

    public func inquiry(lun: Int) throws -> [UInt8] { try gut(befehl(lun: lun, cdb: [0x12, 0, 0, 0, 96, 0], lesen: 96)) }

    public func lunListe() throws -> [Int] {
        let d = try gut(befehl(lun: 0, cdb: [0xA0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0], lesen: 256))
        guard d.count >= 8 else { throw ISCSIFehler.protokoll("REPORT LUNS too short") }
        let n = (Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])) / 8
        return (0..<n).compactMap { 8 + 8 * $0 + 1 < d.count ? (Int(d[8 + 8 * $0] & 0x3f) << 8 | Int(d[9 + 8 * $0])) : nil }
    }

    public func kapazitaet(lun: Int) throws -> (bloecke: UInt64, blockgroesse: Int) {
        let d = try gut(befehl(lun: lun, cdb: [0x9E, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0], lesen: 32))
        guard d.count >= 12 else { throw ISCSIFehler.protokoll("READ CAPACITY(16) too short") }
        let letzter = d[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let bs = Int(d[8]) << 24 | Int(d[9]) << 16 | Int(d[10]) << 8 | Int(d[11])
        guard bs >= 512, bs & (bs - 1) == 0 else { throw ISCSIFehler.protokoll("implausible block size \(bs)") }
        sperre.lock(); blockgroessen[lun] = bs; sperre.unlock()
        return (letzter &+ 1, bs)
    }

    public func modeSense3A(lun: Int, unterseite: UInt8) throws -> [UInt8] {
        let n = Self.modeSenseExakt[unterseite] ?? Self.modeSenseMax
        return try gut(befehl(lun: lun, cdb: [0x5A, 0x08, 0x3A, unterseite, 0, 0, 0, UInt8(n >> 8), UInt8(n & 0xff), 0], lesen: n))
    }

    /// LUN-Groesse in TiB setzen (DroboPro-Testgeraet, alle LUNs vorher ausgehaengt, Aufrufer prueft das). Antwort roh zurueck (Status, Sense), nichts wird interpretiert.
    public func lunGroesseSetzen(tib: Int, txn: UInt8 = 1) throws -> SCSIAntwort {
        guard (1...16).contains(tib) else { throw ISCSIFehler.verboten("LUN size \(tib) TiB outside 1...16") }
        let inq = try inquiry(lun: 0)
        guard inq.count >= 32, String(decoding: inq[16..<32], as: UTF8.self).hasPrefix("DroboPro") else { throw ISCSIFehler.verboten("LUN size change only for a DroboPro") }
        lunGroesseFreigabe = true; defer { lunGroesseFreigabe = false }
        let d = [UInt8(tib >> 24 & 0xff), UInt8(tib >> 16 & 0xff), UInt8(tib >> 8 & 0xff), UInt8(tib & 0xff)]
        return try befehl(lun: 0, cdb: [0xEA, 0x10, 0x00, 0x0F, 0x00, txn, 0x21, 0x00, 0x04, 0x00], daten: d)
    }

    private func blockgroesse(_ lun: Int) throws -> Int {
        sperre.lock(); let b = blockgroessen[lun]; sperre.unlock()
        return try b ?? kapazitaet(lun: lun).blockgroesse
    }

    private func cdb16(_ op: UInt8, _ lba: UInt64, _ n: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 16); c[0] = op; put64(&c, 2, lba); put32(&c, 10, UInt32(n)); return c
    }

    /// Liest `bloecke` Bloecke ab `lba`; stueckelt in Befehle <= maxDatenmenge.
    public func lesen(lun: Int, lba: UInt64, bloecke: Int) throws -> [UInt8] {
        let bs = try blockgroesse(lun), pro = Self.maxDatenmenge / bs
        var aus: [UInt8] = []; var rest = bloecke, pos = lba
        while rest > 0 {
            let n = min(rest, pro)
            let d = try gut(befehl(lun: lun, cdb: cdb16(0x88, pos, n), lesen: n * bs))
            guard d.count == n * bs else { throw ISCSIFehler.protokoll("READ(16) returned \(d.count) of \(n * bs) bytes") }
            aus += d; rest -= n; pos += UInt64(n)
        }
        return aus
    }

    /// Schreibt `daten` (Vielfaches der Blockgroesse) ab `lba`; stueckelt in Befehle <= maxDatenmenge.
    public func schreiben(lun: Int, lba: UInt64, daten: [UInt8]) throws {
        let bs = try blockgroesse(lun), pro = Self.maxDatenmenge / bs
        guard !daten.isEmpty, daten.count % bs == 0 else { throw ISCSIFehler.verboten("write length \(daten.count) is not a multiple of block size \(bs)") }
        var pos = lba, off = 0
        while off < daten.count {
            let n = min((daten.count - off) / bs, pro)
            _ = try gut(befehl(lun: lun, cdb: cdb16(0x8A, pos, n), daten: Array(daten[off..<off + n * bs])))
            off += n * bs; pos += UInt64(n)
        }
    }
}
