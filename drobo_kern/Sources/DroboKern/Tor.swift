import Foundation

/// Torpruefungen wie tools/drobo_lesen.sh Abschnitt 2 (Python): Volume-Header-Signatur, attr 0x100 gesetzt, 0x800/0x4000 nicht, Journal leer.
public struct Torbericht: Equatable {
    public var signatur = ""
    public var attr: UInt32 = 0
    public var journal = "kein Journal"
    public var probleme: [String] = []
    public var ok: Bool { probleme.isEmpty }
}

private func be32(_ a: [UInt8], _ o: Int) -> UInt32 { a[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
private func be64(_ a: [UInt8], _ o: Int) -> UInt64 { a[o..<o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
private func le64(_ a: [UInt8], _ o: Int) -> UInt64 { a[o..<o + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }

/// `pfad` ist ein Geraet (/dev/rdiskNsM) oder eine Abbilddatei; nur O_RDONLY, nie schreibend.
public func torpruefung(pfad: String) throws -> Torbericht {
    let fd = open(pfad, O_RDONLY)
    if fd < 0 {
        if errno == EACCES || errno == EPERM { throw Fehler.keinZugriff(pfad) }
        throw Fehler.tor(["\(pfad) nicht lesbar: \(String(cString: strerror(errno)))"])
    }
    defer { close(fd) }
    func lies(_ off: UInt64, _ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        let got = pread(fd, &b, n, off_t(off))
        return got < n ? Array(b[0..<max(got, 0)]) + [UInt8](repeating: 0, count: n - max(got, 0)) : b
    }
    var r = Torbericht()
    let vh = Array(lies(0, 4096)[1024..<1536])
    r.signatur = String(decoding: vh[0..<2], as: UTF8.self)
    guard vh[0..<2] == [0x48, 0x2B] || vh[0..<2] == [0x48, 0x58] else {
        r.probleme.append("kein HFS+/HFSX-Volume-Header (Signatur \(vh[0..<2].map { String(format: "%02x", $0) }.joined()))")
        return r
    }
    r.attr = be32(vh, 4)
    let bs = UInt64(be32(vh, 40))
    if r.attr & 0x100 == 0 { r.probleme.append("0x100 (sauber ausgehaengt) nicht gesetzt") }
    if r.attr & 0x800 != 0 { r.probleme.append("0x800 (inkonsistent) gesetzt") }
    if r.attr & 0x4000 != 0 { r.probleme.append("0x4000 gesetzt") }
    if r.attr & 0x2000 != 0 {
        let jib = lies(UInt64(be32(vh, 12)) * bs, 512)
        if be32(jib, 0) & 4 != 0 { r.journal = "nie benutzt (needs init) -> leer" } else {
            let jh = lies(be64(jib, 36), 512)
            let (start, end) = (le64(jh, 8), le64(jh, 16))
            r.journal = "start=\(start) end=\(end) -> " + (start == end ? "leer" : "NICHT LEER")
            if start != end { r.probleme.append("Journal nicht leer (Replay wuerde schreiben)") }
        }
    }
    return r
}
