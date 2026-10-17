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

/// Volumename aus dem HFS+-Katalog: der Wurzelordner steht unter dem Schluessel (parentID 1, Volumename) und ist der ERSTE Satz des ersten Blatts. `lies` liest ab Partitionsanfang
/// (sektorweise ausgerichtet). Liest nur den Kopf, die Kopf-Knoten- und die erste Blattseite des Katalogs im ersten Extent; nil = nicht lesbar (nie raten).
public func hfsVolumeName(lies: (UInt64, Int) throws -> [UInt8]) -> String? {
    guard let vh = try? lies(1024, 512), vh.count == 512, vh[0] == 0x48, vh[1] == 0x2B || vh[1] == 0x58 else { return nil }
    let bs = UInt64(be32(vh, 40)), start = UInt64(be32(vh, 288)), n = UInt64(be32(vh, 292))      // Katalog-Fork (VH+272): Extent 0 bei +16
    guard bs >= 512, n > 0, let kopf = try? lies(start * bs, 512), kopf.count == 512 else { return nil }
    let erstes = UInt64(be32(kopf, 24)), knoten = UInt64(kopf[32]) << 8 | UInt64(kopf[33])     // BTHeaderRec: firstLeafNode (+10), nodeSize (+18), je +14 Knotenkopf
    guard knoten >= 512, knoten <= 32768, knoten % 512 == 0, (erstes + 1) * knoten <= n * bs, let b = try? lies(start * bs + erstes * knoten, Int(knoten)), b.count == Int(knoten), b[8] == 0xFF else { return nil }
    let satz = Int(b[Int(knoten) - 2]) << 8 | Int(b[Int(knoten) - 1])
    guard Int(b[10]) << 8 | Int(b[11]) > 0, satz + 8 <= b.count, be32(b, satz + 2) == 1 else { return nil }
    let len = Int(b[satz + 6]) << 8 | Int(b[satz + 7])
    guard len > 0, satz + 8 + 2 * len <= b.count else { return nil }
    let u = (0..<len).map { UInt16(b[satz + 8 + 2 * $0]) << 8 | UInt16(b[satz + 9 + 2 * $0]) }
    return String(decoding: u, as: UTF16.self)
}

public let iscsiVorgabeOrt = "/private/tmp/drobo_iscsi_mnt"

/// Einhaengeort einer iSCSI-LUN laut Einstellung: wie beim 5C-Weg die Vorgabe /Volumes (-> der Dienst legt /Volumes/<Volumename> an, Finder-Seitenleiste),
/// sonst nil = der alte Ort unter /private/tmp (nur CLI / ausdrueckliche Wahl). Nie ein fester /private/tmp-Ort fuer die App-Vorgabe.
public func iscsiEinhaengeort(einstellung: String) -> String? { einstellung == vorgabeVolumes ? vorgabeVolumes : nil }

/// LUN-Nummer aus der Quelle eines iSCSI-Mounts in der Mount-Tabelle: iscsi://127.0.0.1:PORT/IQN/LUN. nil = kein iSCSI-Mount.
public func iscsiLunAusQuelle(_ von: String) -> Int? {
    guard von.hasPrefix("iscsi://"), let l = von.split(separator: "/").last else { return nil }
    return Int(l)
}

/// Einhaengen ueber den Hilfsdienst: Weiterleitung (Port) holen, Volume-UUID und Partitionsgroesse aus der LUN lesen, Freigabe im Container des iSCSI-Moduls setzen,
/// `mount -F -t hfsdropro iscsi://127.0.0.1:PORT/IQN/LUN ORT`. Der Ort liegt nie unter $HOME (Spotlight).
public func iscsiEinhaengen(host: String, lun: Int, schreiben: Bool, ziel: String?, ort: String?, sicherung: (ort: String, anzahl: Int)? = nil, ohneSicherung: Bool = false,
                            volumenName: String? = nil, meldung: (String) -> Void, weckfortschritt: ((Int) -> Void)? = nil,
                            ordner: (anlegen: (String, String) throws -> String, entfernen: (String) -> Void) = ({ try helferISCSIOrdnerAnlegen(uuid: $0, name: $1) }, { _ = helferISCSIOrdnerEntfernen(pfad: $0) })) throws {
    var ort = ort ?? "\(iscsiVorgabeOrt)\(lun)"
    let ueberDienst = ort == vorgabeVolumes
    guard !ort.hasPrefix(NSHomeDirectory() + "/"), ort != NSHomeDirectory() else { throw Fehler.ortUnterHome(ort) }
    let port = try helferISCSIWeiterleitung(host: host)
    meldung("helper forwards 127.0.0.1:\(port) -> \(host):3260")
    let d = try ISCSISitzung(host: "127.0.0.1", port: port); let ziele = try d.ziele(); d.abmelden()
    guard let iqn = ziel ?? ziele.first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    let s = try ISCSISitzung(host: "127.0.0.1", port: port, ziel: iqn, zeitgrenze: 10, ersteZeitgrenze: ISCSISitzung.ersteZeitgrenzeNetz, zweck: "mount-lun\(lun)")
    do { try netzAufwecken(sitzung: s, fortschritt: weckfortschritt) } catch { s.abmelden(); throw error }    // Weckphase in DERSELBEN Sitzung, danach erst lesen
    s.folgeZeitgrenze = 30; s.draht.zeitgrenze = 30     // grosse Lesezuege wie bisher
    let teil = try GPT.ersteHFS { try s.lesen(lun: lun, lba: $0, bloecke: $1) }
    guard let p = teil else { s.abmelden(); throw ISCSIFehler.protokoll("LUN \(lun) has no HFS+ partition") }
    let vh = try s.lesen(lun: lun, lba: p.ersterLBA + 2, bloecke: 1)       // Offset 1024 der Partition
    let hfsName = hfsVolumeName(lies: partitionLeser(s, lun: lun, partition: p))      // so heisst das Volume im Finder; der Ordner unter /Volumes soll genauso heissen
    var gesichert: String?
    if schreiben, let si = sicherung, let u = hfsVolumeUUID(vh: vh) {
        do { gesichert = try netzSicherung(sitzung: s, lun: lun, partition: p, uuid: u, ort: si.ort, anzahl: si.anzahl).ordner } catch { s.abmelden(); throw error }
        meldung("metadata backup: \(gesichert!)")
    } else if schreiben && !ohneSicherung { s.abmelden(); throw AppFehler.sicherungOrt("Schreiben ohne Metadaten-Sicherung wird nicht eingehaengt: Sicherungsort fehlt (CLI: drobo backup-location PFAD, oder --no-backup)") }
    s.abmelden()                                                            // vor dem Mount: eine Sitzung zur Zeit (die DroboPro bedient nur eine)
    guard let uuid = hfsVolumeUUID(vh: vh) else { throw ISCSIFehler.protokoll("partition has no HFS+ volume header with a volume ID") }
    let ordnerName = iscsiOrdnerName(hfs: hfsName, gespeichert: volumenName, lun: lun)
    let modus = schreiben ? "schreiben" : "nurlesen"
    try helferISCSIFreigabeSetzen(uuid: uuid, modus: modus, maxBytes: p.bloecke * 512)
    meldung("permission \(uuid): \(modus), max_bytes \(p.bloecke * 512)")
    if ueberDienst { ort = try ordner.anlegen(uuid, ordnerName) } else { try FileManager.default.createDirectory(atPath: ort, withIntermediateDirectories: true) }
    let url = "iscsi://127.0.0.1:\(port)/\(iqn)/\(lun)"
    var (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdropro", url, ort])
    if rc != 0 { Thread.sleep(forTimeInterval: 3); (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdropro", url, ort]) }
    guard rc == 0 else { if ueberDienst { ordner.entfernen(ort) }; throw Fehler.mountFehlgeschlagen(out) }
    meldung("mounted \(modus): \(ort)")
}

public func iscsiAushaengen(ort: String) throws {
    let (rc, out) = ausfuehren("/sbin/umount", [ort])
    guard rc == 0 else { throw Fehler.aushaengenFehlgeschlagen(out) }
    if ort.hasPrefix(vorgabeVolumes + "/") { _ = helferISCSIOrdnerEntfernen(pfad: ort) }      // den vom Dienst angelegten Ordner wieder wegraeumen
}

/// Haengt die LUN dort aus, wo sie laut Mount-Tabelle wirklich eingehaengt ist (/Volumes/<Name> oder alter /private/tmp-Ort).
public func iscsiAushaengen(lun: Int) throws {
    guard let e = netzEinhaengung(lun: lun) else { throw Fehler.nichtEingehaengt("iSCSI LUN \(lun)") }
    try iscsiAushaengen(ort: e.ort)
}

/// Alle LUNs mit HFS+ einhaengen (je LUN eigener Ort /private/tmp/drobo_iscsi_mnt<N>, Freigabe je Volume-UUID). Bereits eingehaengte werden uebersprungen,
/// ein Fehler bei einer LUN stoppt die anderen nicht. Rueckgabe: je LUN Fehlertext oder nil.
@discardableResult
public func iscsiAlleEinhaengen(host: String, schreiben: Bool, sicherung: (ort: String, anzahl: Int)? = nil, ohneSicherung: Bool = false, ort: String? = nil, namen: [Int: String] = [:], meldung: (String) -> Void) throws -> [Int: String?] {
    var erg: [Int: String?] = [:]
    for l in try netzLunVerzeichnis(host: host) where l.hatDateisystem {
        if netzEinhaengung(lun: l.lun) != nil { meldung("LUN \(l.lun): already mounted"); erg[l.lun] = .some(nil); continue }
        do { try iscsiEinhaengen(host: host, lun: l.lun, schreiben: schreiben, ziel: nil, ort: ort, sicherung: sicherung, ohneSicherung: ohneSicherung, volumenName: namen[l.lun], meldung: { meldung("LUN \(l.lun): " + $0) }); erg[l.lun] = .some(nil) }
        catch { meldung("LUN \(l.lun): \(error)"); erg[l.lun] = "\(error)" }
    }
    return erg
}

/// Alle eingehaengten iSCSI-LUN-Orte (Mount-Tabelle: /private/tmp/drobo_iscsi_mnt<N>).
public func iscsiEingehaengteLuns(tabelle: [String: Einhaengung] = einhaengungen()) -> [Int] {
    tabelle.keys.compactMap(iscsiLunAusQuelle).sorted()
}

public func iscsiAlleAushaengen(meldung: (String) -> Void) throws {
    for l in iscsiEingehaengteLuns() { try iscsiAushaengen(lun: l); meldung("LUN \(l): unmounted") }
}
