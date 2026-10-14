import Compression
import Darwin
import FSKit
import Foundation

/// HFS-komprimierte Dateien (UF_COMPRESSED), Phase 5a. livefiles_hfs liest nur die (leere) Datengabel; hier wird com.apple.decmpfs ausgewertet.
/// Unterstuetzt: Typ 7 (LZVN im xattr, ab Byte 16) und Typ 8 (LZVN-Bloecke zu 64 KiB in der Ressourcengabel, vorn Tabelle (n+1) LE-u32-Offsets).
/// Block/Strom mit erstem Byte 0x06 = unkomprimiert gespeichert (0x06 ist der LZVN-Endeopcode, also nie ein gueltiger Strombeginn).
/// JEDER andere Typ und jeder Formatfehler -> EIO; nie falsche Bytes ausliefern. Aufruf nur mit gehaltenem libLock.
enum Decmpfs {
    static let blk = 65536
    /// LZVN (roher Strom, kein bvxn-Rahmen) ist in compression.h nicht benannt, libcompression kennt ihn unter 0x900.
    static let lzvn = compression_algorithm(rawValue: 0x900)
    static let tableMaxBlocks = 1 << 22                       // 256 GiB; darueber ist die Tabelle unglaubwuerdig

    static func eio(_ why: String) -> Error { hfsLog.error("decmpfs: \(why, privacy: .public)"); return posixError(EIO) }
    private static func le32(_ a: [UInt8], _ o: Int) -> UInt32 { UInt32(a[o]) | UInt32(a[o + 1]) << 8 | UInt32(a[o + 2]) << 16 | UInt32(a[o + 3]) << 24 }
    private static func le64(_ a: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(a, o)) | UInt64(le32(a, o + 4)) << 32 }

    /// Einen Block/Strom entpacken: src[0] == 0x06 -> Rest roh (Laenge muss stimmen), sonst LZVN (Ergebnislaenge muss `expected` sein). out braucht expected + 1 Byte.
    static func decode(_ src: UnsafeRawBufferPointer, expected: Int, into out: UnsafeMutablePointer<UInt8>) throws {
        guard src.count >= 1 else { throw eio("leerer Block") }
        if src[0] == 0x06 {
            guard src.count - 1 == expected else { throw eio("Rohblock \(src.count - 1) B, erwartet \(expected)") }
            if expected > 0 { memcpy(out, src.baseAddress! + 1, expected) }
            return
        }
        let got = compression_decode_buffer(out, expected + 1, src.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count, nil, lzvn)
        guard got == expected else { throw eio("LZVN entpackt \(got) B, erwartet \(expected)") }
    }

    static func read(node: Node, offset: UInt64, want: Int, dst: UnsafeMutableRawPointer) throws -> Int {
        var x = [UInt8](repeating: 0, count: 4096)
        var xn = 0
        let r = x.withUnsafeMutableBytes { HFS_fsOps.fsops_getxattr!(node, "com.apple.decmpfs", $0.baseAddress, 4096, &xn) }
        guard r == 0, xn >= 16, xn <= 4096 else { throw eio("xattr com.apple.decmpfs r=\(r) n=\(xn)") }
        guard x[0] == 0x66, x[1] == 0x70, x[2] == 0x6d, x[3] == 0x63 else { throw eio("Magic fpmc fehlt") }   // 'fpmc'
        let typ = le32(x, 4), size = le64(x, 8)
        if offset >= size { return 0 }
        let n = Int(min(UInt64(want), size - offset))
        switch typ {
        case 7: return try type7(x, xn, size, offset, n, dst)
        case 8: return try type8(node, size, offset, n, dst)
        default: throw eio("Typ \(typ) nicht unterstuetzt")
        }
    }

    private static func type7(_ x: [UInt8], _ xn: Int, _ size: UInt64, _ offset: UInt64, _ n: Int, _ dst: UnsafeMutableRawPointer) throws -> Int {
        guard size <= 1 << 20 else { throw eio("Typ 7 mit \(size) B unglaubwuerdig") }
        var out = [UInt8](repeating: 0, count: Int(size) + 1)
        try x.withUnsafeBytes { try decode(UnsafeRawBufferPointer(rebasing: $0[16..<xn]), expected: Int(size), into: &out) }
        out.withUnsafeBytes { _ = memcpy(dst, $0.baseAddress! + Int(offset), n) }
        return n
    }

    private static func type8(_ node: Node, _ size: UInt64, _ offset: UInt64, _ n: Int, _ dst: UnsafeMutableRawPointer) throws -> Int {
        let nb = Int((size + UInt64(blk) - 1) / UInt64(blk))
        guard nb >= 1, nb <= tableMaxBlocks else { throw eio("Typ 8: \(nb) Bloecke") }
        var stream: UVFSStreamNode? = nil
        let lr = HFS_fsOps.fsops_stream_lookup!(node, &stream)
        guard lr == 0, let st = stream else { throw eio("Ressourcengabel nicht lesbar r=\(lr)") }
        defer { _ = HFS_fsOps.fsops_stream_reclaim!(st) }
        func fork(_ off: Int, _ len: Int) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: len)
            var act = 0
            let r = buf.withUnsafeMutableBytes { HFS_fsOps.fsops_stream_read!(st, UInt64(off), len, $0.baseAddress, &act) }
            guard r == 0, act == len else { throw eio("Ressourcengabel Lesen off=\(off) len=\(len) r=\(r) act=\(act)") }
            return buf
        }
        let tb = (nb + 1) * 4
        let traw = try fork(0, tb)
        var t = [Int](repeating: 0, count: nb + 1)
        for i in 0...nb { t[i] = Int(le32(traw, i * 4)) }
        guard t[0] >= tb else { throw eio("Offsettabelle beginnt vor ihrem Ende") }
        for i in 0..<nb { guard t[i + 1] > t[i], t[i + 1] - t[i] <= blk + 1 else { throw eio("Offsettabelle Block \(i): \(t[i])..\(t[i + 1])") } }
        let first = Int(offset / UInt64(blk)), last = Int((offset + UInt64(n) - 1) / UInt64(blk))
        let data = try fork(t[first], t[last + 1] - t[first])
        var tmp = [UInt8](repeating: 0, count: blk + 1)
        var done = 0
        for i in first...last {
            let expected = Int(min(UInt64(blk), size - UInt64(i) * UInt64(blk)))
            try data.withUnsafeBytes { try decode(UnsafeRawBufferPointer(rebasing: $0[(t[i] - t[first])..<(t[i + 1] - t[first])]), expected: expected, into: &tmp) }
            let s = i == first ? Int(offset - UInt64(first) * UInt64(blk)) : 0
            let e = i == last ? Int(offset + UInt64(n) - UInt64(last) * UInt64(blk)) : expected
            tmp.withUnsafeBytes { _ = memcpy(dst + done, $0.baseAddress! + s, e - s) }
            done += e - s
        }
        return done
    }
}
