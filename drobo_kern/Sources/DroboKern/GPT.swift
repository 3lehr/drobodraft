import Foundation

/// GPT lesen (erste HFS+-Partition) und bauen (protektiver MBR + Header + 128 Eintraege + Sicherungs-GPT). 512-B-Sektoren.
/// Wird auch vom FSKit-Modul hfsdropro kompiliert: keine Abhaengigkeit ausser Foundation und ISCSI.swift (put32/put64).
public enum GPT {
    /// HFS+ (48465300-0000-11AA-AA11-00306543ECAC) in der GPT-Byte-Reihenfolge (die ersten drei Felder little-endian).
    public static let hfsTyp: [UInt8] = [0x00, 0x53, 0x46, 0x48, 0x00, 0x00, 0xAA, 0x11, 0xAA, 0x11, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC]
    public struct Partition: Equatable { public var ersterLBA: UInt64; public var letzterLBA: UInt64
        public var bloecke: UInt64 { letzterLBA - ersterLBA + 1 } }

    static func le32(_ a: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(a[o + $1]) << UInt32(8 * $1) } }
    static func le64(_ a: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(a[o + $1]) << UInt64(8 * $1) } }
    static func setLE32(_ a: inout [UInt8], _ o: Int, _ v: UInt32) { for i in 0..<4 { a[o + i] = UInt8(truncatingIfNeeded: v >> UInt32(8 * i)) } }
    static func setLE64(_ a: inout [UInt8], _ o: Int, _ v: UInt64) { for i in 0..<8 { a[o + i] = UInt8(truncatingIfNeeded: v >> UInt64(8 * i)) } }

    public static func crc32(_ d: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 } }
        return ~c
    }

    /// `lies(lba, anzahl)` liefert anzahl*512 Byte. Wirft bei ungueltiger GPT (Signatur, Header-CRC, Eintrags-CRC); nil = keine HFS+-Partition.
    public static func ersteHFS(lies: (UInt64, Int) throws -> [UInt8]) throws -> Partition? {
        let h = try lies(1, 1)
        guard h.count >= 512, Array(h[0..<8]) == Array("EFI PART".utf8) else { throw ISCSIFehler.protokoll("no GPT header at LBA 1") }
        let hs = Int(le32(h, 12))
        guard hs >= 92, hs <= 512 else { throw ISCSIFehler.protokoll("GPT header size \(hs)") }
        var kopf = Array(h[0..<hs]); setLE32(&kopf, 16, 0)
        guard crc32(kopf) == le32(h, 16) else { throw ISCSIFehler.protokoll("GPT header CRC mismatch") }
        let (elba, n, es) = (le64(h, 72), Int(le32(h, 80)), Int(le32(h, 84)))
        guard es >= 128, es <= 512, es & (es - 1) == 0, n >= 1, n <= 256 else { throw ISCSIFehler.protokoll("GPT entry table \(n) x \(es)") }
        let bytes = n * es
        let e = Array(try lies(elba, (bytes + 511) / 512).prefix(bytes))
        guard e.count == bytes, crc32(e) == le32(h, 88) else { throw ISCSIFehler.protokoll("GPT entry CRC mismatch") }
        for i in 0..<n {
            let o = i * es
            if Array(e[o..<o + 16]) == hfsTyp {
                let (a, z) = (le64(e, o + 32), le64(e, o + 40))
                guard a >= 34, z >= a else { throw ISCSIFehler.protokoll("GPT partition \(a)...\(z) invalid") }
                return Partition(ersterLBA: a, letzterLBA: z)
            }
        }
        return nil
    }

    /// Eine Platte mit `plattenBloecke` Sektoren und EINER HFS+-Partition. primaer = LBA 0...33 (17408 B), sicherung = die letzten 33 Sektoren.
    public static func bauen(plattenBloecke: UInt64, partition: Partition, plattenGUID: [UInt8], partitionsGUID: [UInt8], name: String) -> (primaer: [UInt8], sicherung: [UInt8]) {
        let letzter = plattenBloecke - 1
        var mbr = [UInt8](repeating: 0, count: 512)
        mbr[446 + 2] = 0x02; mbr[446 + 4] = 0xEE; mbr[446 + 5] = 0xFF; mbr[446 + 6] = 0xFF; mbr[446 + 7] = 0xFF
        setLE32(&mbr, 446 + 8, 1); setLE32(&mbr, 446 + 12, UInt32(min(letzter, 0xFFFF_FFFF))); mbr[510] = 0x55; mbr[511] = 0xAA
        var tab = [UInt8](repeating: 0, count: 128 * 128)
        tab.replaceSubrange(0..<16, with: hfsTyp); tab.replaceSubrange(16..<32, with: partitionsGUID)
        setLE64(&tab, 32, partition.ersterLBA); setLE64(&tab, 40, partition.letzterLBA)
        for (i, u) in name.utf16.prefix(36).enumerated() { tab[56 + 2 * i] = UInt8(u & 0xff); tab[57 + 2 * i] = UInt8(u >> 8) }
        func kopf(selbst: UInt64, andere: UInt64, tabLBA: UInt64) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: 512)
            h.replaceSubrange(0..<8, with: Array("EFI PART".utf8)); h[10] = 1; h[12] = 92
            setLE64(&h, 24, selbst); setLE64(&h, 32, andere); setLE64(&h, 40, 34); setLE64(&h, 48, letzter - 33)
            h.replaceSubrange(56..<72, with: plattenGUID); setLE64(&h, 72, tabLBA); setLE32(&h, 80, 128); setLE32(&h, 84, 128); setLE32(&h, 88, crc32(tab))
            setLE32(&h, 16, crc32(Array(h[0..<92]))); return h
        }
        return (mbr + kopf(selbst: 1, andere: letzter, tabLBA: 2) + tab, tab + kopf(selbst: letzter, andere: 1, tabLBA: letzter - 32))
    }
}
