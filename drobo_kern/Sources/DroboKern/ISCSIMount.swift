import CommonCrypto
import Foundation

/// HFS-Volume-UUID wie diskutil / lifs_volume_uuid: MD5(Namensraum-UUID + FinderInfo[6..7] = VH-Bytes 104..111), Version 3 / Variante 1. nil = Volume ohne ID.
/// `vh` = die 512 Byte des Volume-Headers (Offset 1024 der Partition).
public func hfsVolumeUUID(vh: [UInt8]) -> String? {
    guard vh.count >= 112, vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58, vh[104..<112].contains(where: { $0 != 0 }) else { return nil }
    let ns: [UInt8] = [0xB3, 0xE2, 0x0F, 0x39, 0xF2, 0x92, 0x11, 0xD6, 0x97, 0xA4, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC]
    let eingabe = ns + Array(vh[104..<112])
    var md = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = eingabe.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(eingabe.count), &md) }
    md[6] = (md[6] & 0x0F) | 0x30; md[8] = (md[8] & 0x3F) | 0x80
    return UUID(uuid: (md[0], md[1], md[2], md[3], md[4], md[5], md[6], md[7], md[8], md[9], md[10], md[11], md[12], md[13], md[14], md[15])).uuidString
}

public let iscsiVorgabeOrt = "/private/tmp/drobo_iscsi_mnt"

/// Einhaengen ueber den Hilfsdienst: Weiterleitung (Port) holen, Volume-UUID und Partitionsgroesse aus der LUN lesen, Freigabe im Container des iSCSI-Moduls setzen,
/// `mount -F -t hfsdropro iscsi://127.0.0.1:PORT/IQN/LUN ORT`. Der Ort liegt nie unter $HOME (Spotlight).
public func iscsiEinhaengen(host: String, lun: Int, schreiben: Bool, ziel: String?, ort: String?, meldung: (String) -> Void) throws {
    let ort = ort ?? "\(iscsiVorgabeOrt)\(lun)"
    guard !ort.hasPrefix(NSHomeDirectory() + "/"), ort != NSHomeDirectory() else { throw Fehler.ortUnterHome(ort) }
    let port = try helferISCSIWeiterleitung(host: host)
    meldung("helper forwards 127.0.0.1:\(port) -> \(host):3260")
    let d = try ISCSISitzung(host: "127.0.0.1", port: port); let ziele = try d.ziele(); d.abmelden()
    guard let iqn = ziel ?? ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    let s = try ISCSISitzung(host: "127.0.0.1", port: port, ziel: iqn, zeitgrenze: 30)
    let teil = try GPT.ersteHFS { try s.lesen(lun: lun, lba: $0, bloecke: $1) }
    guard let p = teil else { s.abmelden(); throw ISCSIFehler.protokoll("LUN \(lun) has no HFS+ partition") }
    let vh = try s.lesen(lun: lun, lba: p.ersterLBA + 2, bloecke: 1)       // Offset 1024 der Partition
    s.abmelden()                                                            // vor dem Mount: eine Sitzung zur Zeit (die DroboPro bedient nur eine)
    guard let uuid = hfsVolumeUUID(vh: vh) else { throw ISCSIFehler.protokoll("partition has no HFS+ volume header with a volume ID") }
    let modus = schreiben ? "schreiben" : "nurlesen"
    try helferISCSIFreigabeSetzen(uuid: uuid, modus: modus, maxBytes: p.bloecke * 512)
    meldung("permission \(uuid): \(modus), max_bytes \(p.bloecke * 512)")
    try FileManager.default.createDirectory(atPath: ort, withIntermediateDirectories: true)
    let url = "iscsi://127.0.0.1:\(port)/\(iqn)/\(lun)"
    var (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdropro", url, ort])
    if rc != 0 { Thread.sleep(forTimeInterval: 3); (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdropro", url, ort]) }
    guard rc == 0 else { throw Fehler.mountFehlgeschlagen(out) }
    meldung("mounted \(modus): \(ort)")
}

public func iscsiAushaengen(ort: String) throws {
    let (rc, out) = ausfuehren("/sbin/umount", [ort])
    guard rc == 0 else { throw Fehler.aushaengenFehlgeschlagen(out) }
}
