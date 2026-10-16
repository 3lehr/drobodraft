import Foundation

public let MiB: UInt64 = 1 << 20

func be16(_ a: [UInt8], _ o: Int) -> UInt16 { UInt16(a[o]) << 8 | UInt16(a[o + 1]) }
func be32(_ a: [UInt8], _ o: Int) -> UInt32 { a[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
func be64(_ a: [UInt8], _ o: Int) -> UInt64 { a[o..<o + 8].reduce(0) { $0 << 8 | UInt64($1) } }

public struct Ext: Equatable { var start: UInt32; var anzahl: UInt32 }

struct HFSFork { var logical: UInt64; var blocks: UInt32; var inline: [Ext] }

/// Nur lesend (O_RDONLY): Volume-Header, Forks samt Extents-Overflow (TN1150). Geraet oder Abbilddatei. Port von tools/hfs_attr_diagnose.py.
final class HFSLeser {
    static let forkInfo: [(name: String, off: Int, id: UInt32)] = [("allocation", 112, 6), ("extents", 192, 3), ("catalog", 272, 4), ("attributes", 352, 8), ("startup", 432, 7)]
    let fd: Int32
    let pfad: String
    var vh: [UInt8] = []
    var blockSize: UInt64 = 0
    var totalBlocks: UInt32 = 0
    var freeBlocks: UInt32 = 0
    var forks: [String: HFSFork] = [:]

    init(pfad: String) throws {
        self.pfad = pfad
        fd = open(pfad, O_RDONLY)
        if fd < 0 {
            if errno == EACCES || errno == EPERM { throw Fehler.keinZugriff(pfad) }
            throw AppFehler.sicherung("\(pfad) nicht lesbar: \(String(cString: strerror(errno)))")
        }
        vh = try lies(1024, 512)
        guard vh.count == 512, vh[0..<2] == [0x48, 0x2B] || vh[0..<2] == [0x48, 0x58] else { close(fd); throw AppFehler.sicherung("keine HFS+-Signatur in \(pfad)") }
        blockSize = UInt64(be32(vh, 40)); totalBlocks = be32(vh, 44); freeBlocks = be32(vh, 48)
        guard blockSize >= 512, blockSize & (blockSize - 1) == 0 else { close(fd); throw AppFehler.sicherung("unplausible Blockgroesse \(blockSize)") }
        for (n, o, _) in Self.forkInfo { forks[n] = Self.fork(vh, o) }
    }
    deinit { close(fd) }

    static func fork(_ b: [UInt8], _ o: Int) -> HFSFork {
        HFSFork(logical: be64(b, o), blocks: be32(b, o + 12),
                inline: (0..<8).map { Ext(start: be32(b, o + 16 + 8 * $0), anzahl: be32(b, o + 20 + 8 * $0)) }.filter { $0.anzahl > 0 })
    }

    /// Rohgeraete verlangen ausgerichtete Lesezugriffe: auf 4096 erweitern, zurueckschneiden. Kuerzere Rueckgabe = Dateiende.
    func lies(_ off: UInt64, _ n: Int) throws -> [UInt8] {
        let start = off - off % 4096
        let end = (off + UInt64(n) + 4095) / 4096 * 4096
        var buf = [UInt8](repeating: 0, count: Int(end - start)); var got = 0
        while got < buf.count {
            let rest = buf.count - got, fd = self.fd, pos = off_t(start) + off_t(got)
            let r = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, rest, pos) }
            if r < 0 { throw AppFehler.sicherung("Lesefehler bei \(off): \(String(cString: strerror(errno)))") }
            if r == 0 { break }
            got += r
        }
        let a = Int(off - start)
        guard got > a else { return [] }
        return Array(buf[a..<min(got, a + n)])
    }

    func mapExtents(_ ext: [Ext], _ fileOff: UInt64, _ size: UInt64) -> UInt64? {
        var blk = fileOff / blockSize
        for e in ext {
            if blk < UInt64(e.anzahl) {
                if fileOff % blockSize + size > (UInt64(e.anzahl) - blk) * blockSize { return nil }
                return (UInt64(e.start) + blk) * blockSize + fileOff % blockSize
            }
            blk -= UInt64(e.anzahl)
        }
        return nil
    }

    func overflowExtents(_ fileID: UInt32) throws -> [Ext] {
        let ext = forks["extents"]!.inline
        guard let h0 = mapExtents(ext, 0, 512) else { throw AppFehler.sicherung("Extents-Datei: Kopfknoten nicht von Extents gedeckt") }
        let head = try lies(h0, 512)
        guard head.count == 512 else { throw AppFehler.sicherung("Extents-Datei: Kopfknoten unlesbar") }
        let nodeSize = UInt64(be16(head, 14 + 18)); var node = be32(head, 14 + 10)
        guard nodeSize >= 512 else { throw AppFehler.sicherung("Extents-Datei: unplausible Knotengroesse") }
        var found: [(UInt32, [Ext])] = []; var seen = Set<UInt32>()
        while node != 0, !seen.contains(node) {
            seen.insert(node)
            guard let o = mapExtents(ext, UInt64(node) * nodeSize, nodeSize) else { throw AppFehler.sicherung("Extents-Overflow-Knoten \(node) nicht von Extents gedeckt") }
            let raw = try lies(o, Int(nodeSize))
            guard raw.count == Int(nodeSize) else { throw AppFehler.sicherung("Extents-Overflow-Knoten \(node) unlesbar") }
            let nrec = Int(be16(raw, 10))
            for i in 0..<nrec {
                let r = Int(be16(raw, raw.count - 2 * (i + 1)))
                let klen = Int(be16(raw, r)); let forkType = raw[r + 2]
                let fid = be32(raw, r + 4); let startBlk = be32(raw, r + 8)
                if fid == fileID, forkType == 0 {
                    let body = r + 2 + klen
                    found.append((startBlk, (0..<8).map { Ext(start: be32(raw, body + 8 * $0), anzahl: be32(raw, body + 8 * $0 + 4)) }))
                }
            }
            node = be32(raw, 0)
        }
        return found.sorted { $0.0 < $1.0 }.flatMap { $0.1 }.filter { $0.anzahl > 0 }
    }

    /// Inline-Extents plus (falls noetig) Overflow-Extents; Extents-Datei selbst hat nie Overflow.
    func vollExtents(_ name: String) throws -> [Ext] {
        let f = forks[name]!; let id = Self.forkInfo.first { $0.name == name }!.id
        var e = f.inline
        if e.reduce(0, { $0 + UInt64($1.anzahl) }) < UInt64(f.blocks), id != 3 { e += try overflowExtents(id) }
        return e
    }

    /// Streamt einen Fork in <= 4 MiB-Stuecken ueber seine Extents (nur lesend).
    func strome(_ ext: [Ext], logical: UInt64, _ stueck: ([UInt8]) throws -> Void) throws {
        var left = logical
        for e in ext where left > 0 {
            let len = min(UInt64(e.anzahl) * blockSize, left)
            var done: UInt64 = 0
            while done < len {
                let n = Int(min(4 * MiB, len - done))
                let b = try lies(UInt64(e.start) * blockSize + done, n)
                guard b.count == n else { throw AppFehler.sicherung("Lesefehler: Offset \(UInt64(e.start) * blockSize + done), \(b.count) statt \(n) Byte") }
                try stueck(b); done += UInt64(n)
            }
            left -= len
        }
    }

    /// Volumeende (fuer Alternate-VH bei Ende-1024): Abbilddatei = Dateigroesse, sonst totalBlocks*Blockgroesse; muss dort H+/HX tragen.
    func volumeEnde(partitionsgroesse: UInt64? = nil) throws -> UInt64 {
        var st = stat(); fstat(fd, &st)
        var kandidaten: [UInt64] = []
        if st.st_mode & S_IFMT == S_IFREG { kandidaten = [UInt64(st.st_size)] }
        else { kandidaten = [UInt64(totalBlocks) * blockSize] + (partitionsgroesse.map { [$0] } ?? []) }
        for k in kandidaten where k > 2 * MiB {
            if let a = try? lies(k - 1024, 2), a == [0x48, 0x2B] || a == [0x48, 0x58] { return k }
        }
        throw AppFehler.sicherung("Alternate-VH fehlt (kein H+/HX bei Ende-1024) -- Volumeende nicht bestimmbar")
    }
}
