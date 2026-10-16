import Foundation

private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

/// Gegenprobe gegen ein echtes iSCSI-Ziel (DroboPro): Discovery, INQUIRY, LUNs, Kapazitaet, erste 8 Sektoren, Statusseiten 3A. Nur lesend.
/// `schreibtest`: schreibt EINEN Sektor mit Muster auf LUN 1 bei `schreibtestLBA`, liest zurueck und stellt Nullen wieder her -
/// nur wenn LUN 1 laut Lesen leer ist (erste 8 Sektoren Nullen, also weder MBR noch GPT); sonst wird nicht geschrieben und das gemeldet.
public func iscsiSonde(host: String, schreibtest: Bool, schreibtestLBA: UInt64 = 64) throws -> String {
    var z: [String] = []
    let d = try ISCSISitzung(host: host)
    let ziele = try d.ziele(); d.abmelden()
    z.append("targets: \(ziele.count)")
    guard let ziel = ziele.first else { return z.joined(separator: "\n") }
    let s = try ISCSISitzung(host: host, ziel: ziel.name)
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
    for u in [UInt8]([0x01, 0x02, 0x06, 0x09]) { z.append("3A/\(String(format: "%02x", u)): " + hex(try s.modeSense3A(lun: 0, unterseite: u))) }
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
