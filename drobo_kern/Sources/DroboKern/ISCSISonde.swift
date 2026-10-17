import Foundation

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Gegenprobe gegen ein echtes iSCSI-Ziel (DroboPro): Discovery, INQUIRY, LUNs, Kapazitaet, erste 8 Sektoren, Statusseiten 3A. Nur lesend.
/// `schreibtest`: schreibt EINEN Sektor mit Muster auf LUN 1 bei `schreibtestLBA`, liest zurueck und stellt Nullen wieder her -
/// nur wenn LUN 1 laut Lesen leer ist (erste 8 Sektoren Nullen, also weder MBR noch GPT); sonst wird nicht geschrieben und das gemeldet.
public func iscsiSonde(host: String, port: UInt16 = 3260, schreibtest: Bool, schreibtestLBA: UInt64 = 64, slotInfo2: Bool = false) throws -> String {
    var z: [String] = []
    let d = try ISCSISitzung(host: host, port: port)
    let ziele = try d.ziele(); d.abmelden()
    z.append("targets: \(ziele.count)")
    guard let ziel = ziele.first else { return z.joined(separator: "\n") }
    let s = try ISCSISitzung(host: host, port: port, ziel: ziel.name)
    defer { s.abmelden() }
    z.append("login keys: " + s.login.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    try s.testUnitReady(lun: 0)
    let inq = try s.inquiry(lun: 0)
    z.append("inquiry: " + String(decoding: inq[8..<min(36, inq.count)], as: UTF8.self))
    let luns = try s.lunListe(); z.append("luns: \(luns)")
    var leer1 = false
    for l in luns {
        let k = try s.kapazitaet(lun: l)
        let b = try s.lesen(lun: l, lba: 0, bloecke: 8)
        let nullen = b.allSatisfy { $0 == 0 }
        z.append("lun \(l): blocks \(k.bloecke) x \(k.blockgroesse) B, first 8 sectors: allzero=\(nullen) mbr=\(hex(Array(b[510..<512]))) gpt=\(b[512..<520].elementsEqual(Array("EFI PART".utf8))) hfs@1024=\(hex(Array(b[1024..<1026]))) sha=\(Digest.kurz(b))")
        if l == 1 { leer1 = nullen }
    }
    for l in luns { if let p = try? GPT.ersteHFS(lies: { try s.lesen(lun: l, lba: $0, bloecke: $1) }), let vh = try? s.lesen(lun: l, lba: p.ersterLBA + 2, bloecke: 1) {
        z.append("lun \(l) HFS+ partition LBA \(p.ersterLBA)...\(p.letzterLBA) volume UUID \(hfsVolumeUUID(vh: vh) ?? "-")") } }
    for u in [UInt8]([0x01, 0x02, 0x06, 0x09, 0x05, 0x30, 0x04, 0x07, 0x03]) { z.append("3A/\(String(format: "%02x", u)): " + hex(try s.modeSense3A(lun: 0, unterseite: u))) }
    // SlotInfo2 (Temperatur, Restlebensdauer, Fehler je Schacht): zuletzt und nur auf Wunsch - bleibt die Antwort aus, haengt die Sitzung bis zur Zeitgrenze.
    if slotInfo2 { let p = try s.modeSense3A(lun: 0, unterseite: 0x35); z.append("3A/35 (\(p.count) bytes): " + hex(p)) }
    if schreibtest {
        guard luns.contains(1) else { z.append("write test skipped: no LUN 1"); return z.joined(separator: "\n") }
        guard leer1 else { z.append("write test skipped: LUN 1 is not empty (partition table or data in the first 8 sectors)"); return z.joined(separator: "\n") }
        let vorher = try s.lesen(lun: 1, lba: schreibtestLBA, bloecke: 1)
        guard vorher.allSatisfy({ $0 == 0 }) else { z.append("write test skipped: target sector not zero"); return z.joined(separator: "\n") }
        let muster = (0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        try s.schreiben(lun: 1, lba: schreibtestLBA, daten: muster)
        let zurueck = try s.lesen(lun: 1, lba: schreibtestLBA, bloecke: 1)
        try s.schreiben(lun: 1, lba: schreibtestLBA, daten: vorher)
        z.append("write test LUN 1 lba \(schreibtestLBA): readback equal=\(zurueck == muster), restored=\(try s.lesen(lun: 1, lba: schreibtestLBA, bloecke: 1) == vorher)")
    }
    return z.joined(separator: "\n")
}

private enum Digest {
    static func kurz(_ b: [UInt8]) -> String { String(b.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16) }   // FNV-1a, nur zum Vergleichen
}

/// Schreibprobe an LUN 1 (Testgeraet): je Groesse ein Bereich ab `ablba`, schreiben, zurueckliest, Bytes vergleichen. Beim ersten Fehler Abbruch, nie ein zweiter Versuch.
public func iscsiSchreibprobe(host: String, port: UInt16 = 3260, ablba: UInt64, groessen: [Int], meldung: (String) -> Void) throws {
    let d = try ISCSISitzung(host: host, port: port); let ziele = try d.ziele(); d.abmelden()
    guard let z = ziele.first?.name else { throw ISCSIFehler.protokoll("no target") }
    let s = try ISCSISitzung(host: host, port: port, ziel: z, zeitgrenze: 30)
    defer { s.abmelden() }
    meldung("negotiated: ImmediateData=\(s.login["ImmediateData"] ?? "-") FirstBurstLength=\(s.login["FirstBurstLength"] ?? "-") MaxBurstLength=\(s.login["MaxBurstLength"] ?? "-") MaxOutstandingR2T=\(s.login["MaxOutstandingR2T"] ?? "-") MaxRecvDataSegmentLength=\(s.login["MaxRecvDataSegmentLength"] ?? "-")")
    var lba = ablba, zufall = SystemRandomNumberGenerator()
    for n in groessen {
        let muster = (0..<n).map { _ in UInt8.random(in: 0...255, using: &zufall) }
        meldung("write LUN 1 lba \(lba) \(n) bytes ...")
        try s.schreiben(lun: 1, lba: lba, daten: muster)
        let zurueck = try s.lesen(lun: 1, lba: lba, bloecke: n / 512)
        meldung("  readback equal=\(zurueck == muster) (\(zurueck.count) bytes)")
        guard zurueck == muster else { throw ISCSIFehler.protokoll("readback differs at lba \(lba)") }
        lba += UInt64(n / 512) + 1024
    }
}
