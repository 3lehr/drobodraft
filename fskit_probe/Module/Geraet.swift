import Darwin
import FSKit
import Foundation

/// Kleinste Gerätequelle für Gate, Backend und Volume: genau die Aufrufe, die das Modul an FSBlockDeviceResource braucht.
/// Block-Modul (5C): FSBlockDeviceResource selbst (Verhalten unverändert). iSCSI-Modul: ein Ausschnitt (erste HFS+-Partition) einer LUN.
protocol Geraet: AnyObject {
    var blockSize: UInt64 { get }
    var physicalBlockSize: UInt64 { get }
    var blockCount: UInt64 { get }
    var isWritable: Bool { get }
    var bsdName: String { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func metadataFlush() throws
}

extension FSBlockDeviceResource: Geraet {}

#if ISCSI_MODUL
/// Partition einer iSCSI-LUN als Gerät: Offsets sind relativ zum Partitionsanfang, 512-B-Sektoren, kein Zugriff ausserhalb der Partition.
/// URL: iscsi://HOST[:PORT]/<IQN>/<LUN>. Schreiben nur sektorgenau (das Backend richtet aus); der Kern-Client stückelt auf <= 524288 B je Befehl.
/// ponytail: kein SYNCHRONIZE CACHE (nicht auf der Allowlist); metadataFlush tut nichts. Ob die DroboPro Schreibcache quittiert, ist ungemessen.
final class IscsiGeraet: Geraet {
    let sitzung: ISCSISitzung
    let lun: Int
    let start: UInt64            // Byte-Offset der Partition in der LUN
    let laenge: UInt64
    var blockSize: UInt64 { 512 }
    var physicalBlockSize: UInt64 { 512 }
    var blockCount: UInt64 { laenge / 512 }
    var isWritable: Bool { true }       // die Entscheidung trifft Gate (Modus nurlesen/schreiben) -> DeviceBackend.forcedReadOnly
    let bsdName: String

    init(sitzung: ISCSISitzung, lun: Int, partition: GPT.Partition, name: String) {
        self.sitzung = sitzung; self.lun = lun; start = partition.ersterLBA * 512; laenge = partition.bloecke * 512; bsdName = name
    }
    deinit { sitzung.abmelden() }

    /// URL -> Sitzung -> GPT -> erste HFS+-Partition.
    static func oeffnen(url: URL) throws -> IscsiGeraet {
        guard url.scheme?.lowercased() == "iscsi", let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host, !host.isEmpty else { throw posixError(EINVAL) }
        let teile = c.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard teile.count == 2, teile[0].hasPrefix("iqn."), let lun = Int(teile[1]), lun >= 0, lun < 256 else { throw posixError(EINVAL) }
        let s = try ISCSISitzung(host: host, port: UInt16(c.port ?? 3260), ziel: teile[0], zeitgrenze: 30)
        guard try s.kapazitaet(lun: lun).blockgroesse == 512 else { throw posixError(ENOTSUP) }
        guard let p = try GPT.ersteHFS(lies: { try s.lesen(lun: lun, lba: $0, bloecke: $1) }) else { throw posixError(ENODEV) }
        return IscsiGeraet(sitzung: s, lun: lun, partition: p, name: "iscsi-lun\(lun)")
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        guard offset >= 0, length >= 0, length <= buffer.count else { throw posixError(EINVAL) }
        let off = UInt64(offset)
        if off >= laenge || length == 0 { return 0 }
        let n = Int(min(UInt64(length), laenge - off))
        let a0 = off / 512 * 512, ende = (off + UInt64(n) + 511) / 512 * 512
        let d = try sitzung.lesen(lun: lun, lba: (start + a0) / 512, bloecke: Int((ende - a0) / 512))
        let kopf = Int(off - a0)
        d.withUnsafeBytes { buffer.baseAddress!.copyMemory(from: $0.baseAddress! + kopf, byteCount: n) }
        return n
    }

    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int {
        guard offset >= 0, length > 0, length <= buffer.count, offset % 512 == 0, length % 512 == 0, UInt64(offset) + UInt64(length) <= laenge else { throw posixError(EINVAL) }
        try sitzung.schreiben(lun: lun, lba: (start + UInt64(offset)) / 512, daten: Array(buffer.prefix(length)))
        return length
    }

    func metadataFlush() throws {}
}
#endif
