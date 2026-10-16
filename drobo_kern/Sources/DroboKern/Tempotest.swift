import Foundation

/// Eigener Testordner fuer die Schreibmessung (nur hier wird geschrieben, danach geloescht).
public let tempoTestordner = ".drobodraft_speedtest"
/// Freier Platz muss mindestens Testgroesse x Reserve betragen.
public let tempoPlatzReserve: UInt64 = 2
let tempoBlock = Int(8 * MiB)

/// Laufende Messung: Rate ueber das letzte Fenster (>= 0,4 s), damit der Zeiger nicht zittert.
public struct TempoFortschritt: Equatable {
    public var art: String          // lesen | schreiben
    public var bytes: UInt64
    public var von: UInt64
    public var mbProSekunde: Double
}

/// Ein Messzyklus: Schreiben und Lesen (Lesen allein bei nur-lesen-Mount). Abgebrochene Phasen sind nil.
public struct TempoZyklus: Equatable {
    public var schreiben: TempoMessung?
    public var lesen: TempoMessung?
}

struct TempoUhr {
    let t0 = DispatchTime.now().uptimeNanoseconds
    var tl: UInt64, bl: UInt64 = 0, rate = 0.0
    init() { tl = t0 }
    mutating func tick(_ bytes: UInt64) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds
        if Double(t - tl) / 1e9 >= 0.4 { rate = Double(bytes - bl) / 1e6 / (Double(t - tl) / 1e9); tl = t; bl = bytes }
        else if rate == 0 { rate = Double(bytes) / 1e6 / max(Double(t - t0) / 1e9, 1e-9) }
        return rate
    }
    var sekunden: Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }
}

/// Schutzregel: Schreiben nur bei rw-Einhaengung (Merker rwAktiv) UND vorhandener Metadaten-Sicherung. Reine Funktion, damit testbar.
public func tempoSchreibenErlaubt(nurlesen: Bool, rwAktiv: Bool, sicherung: String?) throws {
    guard !nurlesen, rwAktiv else { throw AppFehler.tempotest("Schreib-Tempotest nur bei Einhaengen zum Schreiben") }
    guard let s = sicherung, FileManager.default.fileExists(atPath: s + "/" + markerName) else { throw AppFehler.tempotest("Schreib-Tempotest nur mit vorhandener Metadaten-Sicherung") }
}

/// Freier Platz am Ort >= groesse x Reserve, sonst Fehler (vor dem Anlegen der Testdatei).
public func tempoPlatzPruefen(ort: String, groesse: UInt64) throws {
    var s = statfs()
    guard statfs(ort, &s) == 0 else { throw AppFehler.tempotest("Freier Platz nicht ermittelbar: \(String(cString: strerror(errno)))") }
    let frei = UInt64(s.f_bavail) * UInt64(s.f_bsize)
    guard frei >= groesse * tempoPlatzReserve else {
        throw AppFehler.tempotest("Zu wenig freier Platz: \(frei / 1_000_000) MB frei, gebraucht \(groesse * tempoPlatzReserve / 1_000_000) MB (Testgroesse x \(tempoPlatzReserve))")
    }
}

func tempoPuffer() -> UnsafeMutableRawPointer {
    let p = UnsafeMutableRawPointer.allocate(byteCount: tempoBlock, alignment: 4096)
    var z: UInt64 = 0x9E3779B97F4A7C15   // SplitMix64: nicht komprimierbar, damit kein Controller mogelt
    for i in 0..<(tempoBlock / 8) {
        z &+= 0x9E3779B97F4A7C15; var x = z
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9; x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        p.storeBytes(of: x ^ (x >> 31), toByteOffset: i * 8, as: UInt64.self)
    }
    return p
}

/// Liest bis `ziel` Bytes sequentiell ohne Cache aus der Datei. nil = abgebrochen.
func tempoLeseDatei(_ pfad: String, ziel: UInt64, puffer: UnsafeMutableRawPointer, schon: inout UInt64, gesamt: UInt64, uhr: inout TempoUhr,
                    fortschritt: ((TempoFortschritt) -> Void)?, abbrechen: () -> Bool) -> Bool {
    let fd = open(pfad, O_RDONLY); guard fd >= 0 else { return true }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    var n: UInt64 = 0
    while n < ziel {
        if abbrechen() { return false }
        let r = read(fd, puffer, Int(min(UInt64(tempoBlock), ziel - n))); if r <= 0 { break }
        n += UInt64(r); schon += UInt64(r)
        fortschritt?(TempoFortschritt(art: "lesen", bytes: schon, von: gesamt, mbProSekunde: uhr.tick(schon)))
    }
    return true
}

/// Leseliste: groesste Dateien unter `ort` (Suche begrenzt). Schreibt nie.
public func tempoLeseKandidaten(ort: String, minBytes: UInt64 = 16 * MiB, maxDateien: Int = 4, suchgrenze: Int = 50000, abbrechen: () -> Bool = { false }) throws -> [(String, UInt64)] {
    guard let en = FileManager.default.enumerator(atPath: ort) else { throw AppFehler.tempotest("\(ort) nicht lesbar") }
    var kand: [(String, UInt64)] = []; var gesehen = 0
    for case let rel as String in en {
        gesehen += 1; if gesehen > suchgrenze || abbrechen() { break }
        var st = stat()
        if lstat(ort + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFREG, UInt64(st.st_size) >= minBytes { kand.append((ort + "/" + rel, UInt64(st.st_size))) }
        if kand.count >= maxDateien * 4 { break }
    }
    kand.sort { $0.1 > $1.1 }
    guard !kand.isEmpty else { throw AppFehler.tempotest("keine Datei ab \(minBytes / MiB) MiB gefunden") }
    return Array(kand.prefix(maxDateien))
}

/// Lesetempo: groesste vorhandene Dateien (oder `kandidaten`), sequentiell ohne Cache, insgesamt hoechstens `zielBytes`. Schreibt nie. nil = abgebrochen.
public func tempoLesen(ort: String, uuid: String, maxDateien: Int = 4, maxBytesJeDatei: UInt64 = 256 * MiB, minBytes: UInt64 = 16 * MiB, zielBytes: UInt64 = .max,
                       suchgrenze: Int = 50000, kandidaten: [(String, UInt64)]? = nil, ablage: Datenablage? = nil,
                       fortschritt: ((TempoFortschritt) -> Void)? = nil, abbrechen: () -> Bool = { false }) throws -> TempoMessung {
    let liste = try kandidaten ?? tempoLeseKandidaten(ort: ort, minBytes: minBytes, maxDateien: maxDateien, suchgrenze: suchgrenze, abbrechen: abbrechen)
    var rest = zielBytes; var plan: [(String, UInt64)] = []
    for (p, g) in liste { let z = min(g, maxBytesJeDatei, rest); if z == 0 { break }; plan.append((p, z)); rest -= z }
    let gesamt = plan.reduce(0) { $0 + $1.1 }
    let puffer = tempoPuffer(); defer { puffer.deallocate() }
    var uhr = TempoUhr(); var schon: UInt64 = 0; var n = 0
    for (p, z) in plan {
        if !tempoLeseDatei(p, ziel: z, puffer: puffer, schon: &schon, gesamt: gesamt, uhr: &uhr, fortschritt: fortschritt, abbrechen: abbrechen) { throw AppFehler.tempotest("abgebrochen") }
        n += 1
    }
    let sek = uhr.sekunden
    guard n > 0, schon > 0, sek > 0 else { throw AppFehler.tempotest("nichts gelesen") }
    let m = TempoMessung(zeit: jetztText(), art: "lesen", mbProSekunde: (Double(schon) / 1e6) / sek, bytes: schon, dateien: n, uuid: uuid)
    ablage?.tempoAnhaengen(m)
    return m
}

/// Schreib- und Lesezyklus im eigenen Testordner `.drobodraft_speedtest` (immer wieder geloescht, auch bei Abbruch/Fehler).
/// Voraussetzungen (rw eingehaengt, Sicherung) prueft der Aufrufer (Kern.tempoLauf via tempoSchreibenErlaubt); Platz prueft diese Funktion.
public func tempoSchreibenUndLesen(ort: String, uuid: String, groesse: UInt64, ablage: Datenablage? = nil,
                                   fortschritt: ((TempoFortschritt) -> Void)? = nil, abbrechen: () -> Bool = { false }) throws -> TempoZyklus {
    guard groesse > 0 else { throw AppFehler.tempotest("Testgroesse 0") }
    try tempoPlatzPruefen(ort: ort, groesse: groesse)
    let dir = ort + "/" + tempoTestordner
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let p = dir + "/test.bin"
    let puffer = tempoPuffer(); defer { puffer.deallocate() }
    let fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0 else { throw AppFehler.tempotest("Testdatei nicht anlegbar: \(String(cString: strerror(errno)))") }
    _ = fcntl(fd, F_NOCACHE, 1)
    var z = TempoZyklus(); var uhr = TempoUhr(); var done: UInt64 = 0
    while done < groesse {
        if abbrechen() { close(fd); return z }
        let n = Int(min(UInt64(tempoBlock), groesse - done))
        let w = write(fd, puffer, n)
        if w != n { let e = String(cString: strerror(errno)); close(fd); throw AppFehler.tempotest("Schreibfehler: \(e)") }
        done += UInt64(w)
        fortschritt?(TempoFortschritt(art: "schreiben", bytes: done, von: groesse, mbProSekunde: uhr.tick(done)))
    }
    fullsync(fd); close(fd)
    let ws = uhr.sekunden
    let w = TempoMessung(zeit: jetztText(), art: "schreiben", mbProSekunde: (Double(done) / 1e6) / max(ws, 1e-9), bytes: done, dateien: 1, uuid: uuid)
    ablage?.tempoAnhaengen(w); z.schreiben = w
    var luhr = TempoUhr(); var schon: UInt64 = 0
    guard tempoLeseDatei(p, ziel: groesse, puffer: puffer, schon: &schon, gesamt: groesse, uhr: &luhr, fortschritt: fortschritt, abbrechen: abbrechen) else { return z }
    let r = TempoMessung(zeit: jetztText(), art: "lesen", mbProSekunde: (Double(schon) / 1e6) / max(luhr.sekunden, 1e-9), bytes: schon, dateien: 1, uuid: uuid)
    ablage?.tempoAnhaengen(r); z.lesen = r
    return z
}
