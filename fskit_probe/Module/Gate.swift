import Darwin
import FSKit
import Foundation

/// Sperre fuer die Erprobung: das Modul nimmt NUR Test-Abbilder an.
/// Bedingung: Marker "DROBOFSPROBE" im ersten Sektor (liegt in den 1024 unbenutzten Boot-Bytes des HFS+-Volumes) UND Groesse <= 24 GiB (Phase 3: 20-GiB-Abbild fuer Dateien > 16 GiB).
/// Die Drobo (64 TiB), CF-Karte, T7 und Backup 1 tragen weder Marker noch passende Groesse. Freigabe fuer die Drobo erfolgt spaeter ausdruecklich.
enum Gate {
    static let marker = Array("DROBOFSPROBE".utf8)
    static let maxBytes: UInt64 = 24 << 30

    static func deviceBytes(_ dev: Geraet) -> UInt64 { dev.blockCount * dev.blockSize }

    static func readHead(_ dev: Geraet, _ n: Int = 4096) throws -> [UInt8] {
        let len = max(n, Int(dev.physicalBlockSize))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: len, alignment: 4096)
        defer { buf.deallocate() }
        let got = try dev.read(into: UnsafeMutableRawBufferPointer(start: buf, count: len), startingAt: 0, length: len)
        return Array(UnsafeRawBufferPointer(start: buf, count: got))
    }

    enum Modus: String { case nurlesen, schreiben }
    struct Freigabe { let uuid: String; let modus: Modus; let maxBytes: UInt64 }
    /// Zulassung: Marker-Testabbild (schreibbar) oder Eintrag der Freigabeliste (Modus aus der Liste).
    struct Zulassung { let modus: Modus; let grund: String }

    /// Freigabeliste im Container des Moduls (die Sandbox darf ihn lesen): ~/Library/Containers/<Praefix>.drobofsprobe.fsmodule/Data/freigabe.json.
    /// Format: [{"volume_uuid":"<Volume-UUID>","modus":"nurlesen","max_bytes":70368744177664}] oder {"eintraege":[...]}. Unlesbar/ungueltig = leer (nichts freigegeben).
    static var freigabePfad: String { NSHomeDirectory() + "/freigabe.json" }
    static func freigaben() -> [Freigabe] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: freigabePfad)), let j = try? JSONSerialization.jsonObject(with: d) else { return [] }
        let arr = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["eintraege"] as? [[String: Any]]) ?? []
        return arr.compactMap { e in
            guard let u = e["volume_uuid"] as? String, let m = (e["modus"] as? String).flatMap(Modus.init(rawValue:)), let mb = (e["max_bytes"] as? NSNumber)?.uint64Value else { return nil }
            return Freigabe(uuid: u.uppercased(), modus: m, maxBytes: mb)
        }
    }

    /// Reserve fuer die harte Platzsperre (Platz.swift): {"reserve_bytes": N, "eintraege": [...]} (nur Objektform); fehlt = Vorgabe.
    static func reserveBytes() -> UInt64? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: freigabePfad)), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (j["reserve_bytes"] as? NSNumber)?.uint64Value
    }

    /// HFS-Volume-UUID wie diskutil (lifs_volume_uuid: MD5 ueber Namespace + finderInfo[6..7]); nil = Volume ohne ID.
    static func volumeUUID(_ head: [UInt8]) -> String? {
        guard head.count >= 1024 + 512 else { return nil }
        var u = [UInt8](repeating: 0, count: 16)
        let none = head[1024..<(1024 + 512)].withUnsafeBytes { lifs_volume_uuid($0.bindMemory(to: UInt8.self).baseAddress, &u) }
        return none != 0 ? nil : UUID(uuid: (u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15])).uuidString
    }

    /// Entscheidung. Marker-Abbild (wie bisher: <= 24 GiB + Marker) ODER Freigabeeintrag mit passender Volume-UUID und Geraet <= max_bytes.
    static func decide(_ dev: Geraet, head: [UInt8]) -> (Zulassung?, String) {
        let hasMarker = head.count >= marker.count && Array(head[0..<marker.count]) == marker
        if hasMarker {
            if deviceBytes(dev) > maxBytes { return (nil, "Marker, aber Groesse \(deviceBytes(dev)) > \(maxBytes)") }
            return (Zulassung(modus: .schreiben, grund: "Marker"), "")
        }
        guard let u = volumeUUID(head) else { return (nil, "kein Marker, keine Volume-UUID") }
        guard let f = freigaben().first(where: { $0.uuid == u }) else { return (nil, "kein Marker, UUID \(u) nicht in der Freigabeliste") }
        if deviceBytes(dev) > f.maxBytes { return (nil, "UUID \(u) freigegeben, aber Geraet \(deviceBytes(dev)) > max_bytes \(f.maxBytes)") }
        return (Zulassung(modus: f.modus, grund: "Freigabe \(u) \(f.modus.rawValue)"), "")
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
