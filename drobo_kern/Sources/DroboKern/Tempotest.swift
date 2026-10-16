import Foundation

/// Lesetempo: groesste Dateien unter `ort` (Suche begrenzt), sequentiell ohne Cache gelesen. Schreibt nie.
public func tempoLesen(ort: String, uuid: String, maxDateien: Int = 4, maxBytesJeDatei: UInt64 = 256 * MiB, minBytes: UInt64 = 16 * MiB,
                       suchgrenze: Int = 50000, ablage: Datenablage? = nil, abbrechen: () -> Bool = { false }) throws -> TempoMessung {
    guard let en = FileManager.default.enumerator(atPath: ort) else { throw AppFehler.tempotest("\(ort) nicht lesbar") }
    var kand: [(String, UInt64)] = []; var gesehen = 0
    for case let rel as String in en {
        gesehen += 1; if gesehen > suchgrenze || abbrechen() { break }
        var st = stat()
        if lstat(ort + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFREG, UInt64(st.st_size) >= minBytes { kand.append((rel, UInt64(st.st_size))) }
        if kand.count >= maxDateien * 4 { break }
    }
    kand.sort { $0.1 > $1.1 }
    guard !kand.isEmpty else { throw AppFehler.tempotest("keine Datei ab \(minBytes / MiB) MiB gefunden") }
    var bytes: UInt64 = 0, sek = 0.0, n = 0
    for (rel, groesse) in kand.prefix(maxDateien) {
        if abbrechen() { break }
        let fd = open(ort + "/" + rel, O_RDONLY); guard fd >= 0 else { continue }
        _ = fcntl(fd, F_NOCACHE, 1)
        var buf = [UInt8](repeating: 0, count: Int(MiB)); var gelesen: UInt64 = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        while gelesen < min(groesse, maxBytesJeDatei) {
            let r = read(fd, &buf, buf.count); if r <= 0 { break }
            gelesen += UInt64(r)
        }
        sek += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9; bytes += gelesen; n += 1
        close(fd)
    }
    guard n > 0, sek > 0 else { throw AppFehler.tempotest("nichts gelesen") }
    let m = TempoMessung(zeit: jetztText(), art: "lesen", mbProSekunde: (Double(bytes) / 1e6) / sek, bytes: bytes, dateien: n, uuid: uuid)
    ablage?.tempoAnhaengen(m)
    return m
}

/// Schreibtempo nur im eigenen Testordner; Voraussetzungen (rw eingehaengt, Sicherung vorhanden) prueft der Aufrufer in Kern.tempoSchreiben.
public func tempoSchreiben(ort: String, uuid: String, mib: Int = 64, ablage: Datenablage? = nil) throws -> TempoMessung {
    let dir = ort + "/.drobo-tempotest"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let p = dir + "/test.bin"
    let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o600); guard fd >= 0 else { throw AppFehler.tempotest("Testdatei nicht anlegbar: \(String(cString: strerror(errno)))") }
    _ = fcntl(fd, F_NOCACHE, 1)
    let chunk = [UInt8](repeating: 0x5A, count: 128 * 1024); var summe: UInt64 = 0
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<(mib * 8) {
        let w = write(fd, chunk, chunk.count)
        if w != chunk.count { close(fd); throw AppFehler.tempotest("Schreibfehler: \(String(cString: strerror(errno)))") }
        summe += UInt64(w)
    }
    fullsync(fd); close(fd)
    let sek = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    let m = TempoMessung(zeit: jetztText(), art: "schreiben", mbProSekunde: (Double(summe) / 1e6) / max(sek, 1e-9), bytes: summe, dateien: 1, uuid: uuid)
    ablage?.tempoAnhaengen(m)
    return m
}
