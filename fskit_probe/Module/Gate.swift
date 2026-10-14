import Darwin
import FSKit
import Foundation

/// Sperre fuer die Erprobung: das Modul nimmt NUR Test-Abbilder an.
/// Bedingung: Marker "DROBOFSPROBE" im ersten Sektor (liegt in den 1024 unbenutzten Boot-Bytes des HFS+-Volumes) UND Groesse <= 24 GiB (Phase 3: 20-GiB-Abbild fuer Dateien > 16 GiB).
/// Die Drobo (64 TiB), CF-Karte, T7 und Backup 1 tragen weder Marker noch passende Groesse. Freigabe fuer die Drobo erfolgt spaeter ausdruecklich.
enum Gate {
    static let marker = Array("DROBOFSPROBE".utf8)
    static let maxBytes: UInt64 = 24 << 30

    static func deviceBytes(_ dev: FSBlockDeviceResource) -> UInt64 { dev.blockCount * dev.blockSize }

    static func readHead(_ dev: FSBlockDeviceResource, _ n: Int = 4096) throws -> [UInt8] {
        let len = max(n, Int(dev.physicalBlockSize))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 4096)
        defer { buf.deallocate() }
        let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: buf, count: len), startingAt: 0, length: len)
        return Array(UnsafeRawBufferPointer(start: buf, count: got))
    }

    /// nil = erlaubt, sonst Ablehnungsgrund.
    static func refusal(_ dev: FSBlockDeviceResource, head: [UInt8]) -> String? {
        if deviceBytes(dev) > maxBytes { return "Groesse \(deviceBytes(dev)) > \(maxBytes)" }
        if head.count < marker.count || Array(head[0..<marker.count]) != marker { return "kein Marker" }
        return nil
    }

    /// HFS+/HFSX-Volume-Header bei Offset 1024: Signatur 'H+' oder 'HX'.
    static func isHFSPlus(_ head: [UInt8]) -> Bool {
        guard head.count >= 1024 + 2 else { return false }
        let s = (UInt16(head[1024]) << 8) | UInt16(head[1025])
        return s == 0x482B || s == 0x4858
    }

    /// Stabile Container-ID aus dem Finder-Info-UUID-Feld (VH+80+24 .. +32), sonst aus Erstellungsdatum.
    static func containerUUID(_ head: [UInt8]) -> UUID {
        var b = [UInt8](repeating: 0, count: 16)
        let tag = Array("HFSDROBO".utf8)
        for i in 0..<8 { b[i] = tag[i] }
        if head.count >= 1024 + 112 { for i in 0..<8 { b[8 + i] = head[1024 + 104 + i] } }
        if b[8...].allSatisfy({ $0 == 0 }), head.count >= 1024 + 20 { for i in 0..<4 { b[8 + i] = head[1024 + 16 + i] } }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
