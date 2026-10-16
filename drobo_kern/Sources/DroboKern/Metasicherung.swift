import CryptoKit
import Foundation

public struct SicherungsErgebnis: Equatable { public var ordner: String; public var bytes: UInt64; public var dateien: Int }

let markerName = ".drobo-sicherung"

func fullsync(_ fd: Int32) { if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) } }

func sha256Datei(_ pfad: String) throws -> String {
    guard let h = FileHandle(forReadingAtPath: pfad) else { throw AppFehler.sicherung("\(pfad) nicht lesbar") }
    defer { try? h.close() }
    var s = SHA256()
    while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { s.update(data: d) }
    return s.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Naechster vorhandener Vorfahr (Ziel darf noch nicht existieren).
func vorhandenerVorfahr(_ pfad: String) -> String {
    var p = (pfad as NSString).standardizingPath
    while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
    return p
}

func dateisystemInfo(_ pfad: String) -> (von: String, auf: String, frei: UInt64)? {
    var s = statfs()
    guard statfs(vorhandenerVorfahr(pfad), &s) == 0 else { return nil }
    let von = withUnsafePointer(to: &s.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
    let auf = withUnsafePointer(to: &s.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
    return (von, auf, UInt64(s.f_bavail) * UInt64(s.f_bsize))
}

/// Systemplatte (Start-/Datenvolume) oder die Drobo selbst sind als Sicherungsort verboten.
func sicherungsOrtPruefen(_ ort: String, quelle: String?) throws {
    guard ort.hasPrefix("/") else { throw AppFehler.sicherungOrt("Sicherungsort \(ort) ist kein absoluter Pfad") }
    guard let i = dateisystemInfo(Kern.aufgeloest(ort)) else { throw AppFehler.sicherungOrt("Sicherungsort \(ort) nicht pruefbar") }
    if i.auf == "/" || i.auf == "/System/Volumes/Data" {
        throw AppFehler.sicherungOrt("Sicherungsort \(ort) liegt auf der Systemplatte. Anderes Laufwerk waehlen.")
    }
    if let q = quelle {
        let dev = q.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk")
        if i.von == dev { throw AppFehler.sicherungOrt("Sicherungsort \(ort) liegt auf der Drobo selbst. Anderes Laufwerk waehlen.") }
    }
}

public let sicherungsDateien = ["kopf_1MiB.bin", "ende_1MiB.bin", "allocation.bin", "extents.bin", "catalog.bin", "attributes.bin", "startup.bin", "extents.json"]

/// SHA256SUMS lesen und jede genannte Datei neu hashen. Fehlende/abweichende/zusaetzliche Dateien -> Problemliste.
public func sicherungPruefen(ordner: String) -> [String] {
    guard let t = FileManager.default.contents(atPath: ordner + "/SHA256SUMS").map({ String(decoding: $0, as: UTF8.self) }) else { return ["SHA256SUMS fehlt"] }
    var probleme: [String] = []; var genannt = Set<String>()
    for z in t.split(separator: "\n") {
        let teile = z.components(separatedBy: "  ")
        guard teile.count == 2 else { probleme.append("SHA256SUMS: Zeile unlesbar"); continue }
        genannt.insert(teile[1])
        do { if try sha256Datei(ordner + "/" + teile[1]) != teile[0] { probleme.append("\(teile[1]): Pruefsumme weicht ab") } }
        catch { probleme.append("\(teile[1]): \(error)") }
    }
    for n in ["kopf_1MiB.bin", "ende_1MiB.bin", "extents.json"] where !genannt.contains(n) { probleme.append("\(n) fehlt in SHA256SUMS") }
    return probleme
}

/// Metadaten-Sicherung (Format wie tools/hfs_attr_diagnose.py --sichern; Rueckweg tools/hfs_meta_restore.py).
/// Portiert statt Python aufgerufen: laeuft ohne Python/Werkzeugordner in der App, und jeder Schritt ist ein Swift-Test am Abbild.
/// Reihenfolge: Ort pruefen -> Plan + Platz -> in Ordner ".partial" schreiben -> SHA256SUMS neu pruefen -> umbenennen -> Alte (nur eigene) loeschen.
@discardableResult
public func metadatenSichern(quelle: String, ort: String, uuid: String, anzahl: Int, partitionsgroesse: UInt64? = nil,
                             freiBytes: UInt64? = nil, jetzt: Date = Date(), vorPruefung: ((String) -> Void)? = nil) throws -> SicherungsErgebnis {
    try sicherungsOrtPruefen(ort, quelle: quelle)
    let v = try HFSLeser(pfad: quelle)
    let ende = try v.volumeEnde(partitionsgroesse: partitionsgroesse)
    let alt = try v.lies(ende - 1024, 2)

    var plan: [(name: String, fork: HFSFork, id: UInt32, ext: [Ext])] = []
    for (n, _, id) in HFSLeser.forkInfo {
        let f = v.forks[n]!
        if n == "startup" && f.logical == 0 { continue }
        let e = try v.vollExtents(n)
        if e.reduce(0, { $0 + UInt64($1.anzahl) }) * v.blockSize < f.logical { throw AppFehler.sicherung("\(n): Extents decken die logicalSize nicht -- Abbruch, nichts geschrieben") }
        plan.append((n, f, id, e))
    }
    let brauche = plan.reduce(0) { $0 + $1.fork.logical } + 2 * MiB
    let frei = freiBytes ?? dateisystemInfo(Kern.aufgeloest(ort))?.frei ?? 0
    // Neue Sicherung braucht Platz, bevor die alten fallen: Alte werden erst NACH Erfolg geloescht.
    if frei < brauche { throw AppFehler.sicherungPlatz("zu wenig Platz in \(ort): frei \(frei) Byte, benoetigt \(brauche) Byte -- nichts geschrieben") }

    let fm = FileManager.default
    try fm.createDirectory(atPath: ort, withIntermediateDirectories: true)
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
    let name = "\(uuid.uppercased())_\(f.string(from: jetzt))"
    let endgueltig = ort + "/" + name, teil = endgueltig + ".partial"
    guard !fm.fileExists(atPath: endgueltig), !fm.fileExists(atPath: teil) else { throw AppFehler.sicherung("Sicherungsordner \(name) existiert schon") }
    try fm.createDirectory(atPath: teil, withIntermediateDirectories: false)
    do {
        try Data(#"{"app":"Drobo","uuid":"\#(uuid.uppercased())"}"#.utf8).write(to: URL(fileURLWithPath: teil + "/" + markerName))
        var summen: [(String, String)] = []
        func schreibe(_ datei: String, _ erzeuge: (@escaping ([UInt8]) -> Void) throws -> Void) throws {
            guard fm.createFile(atPath: teil + "/" + datei, contents: nil), let h = FileHandle(forWritingAtPath: teil + "/" + datei) else { throw AppFehler.sicherung("\(datei) nicht anlegbar") }
            var s = SHA256(); var fehler: Error?
            try erzeuge { b in
                if fehler != nil { return }
                do { try h.write(contentsOf: Data(b)); s.update(data: b) } catch { fehler = error }
            }
            if let e = fehler { try? h.close(); throw e }
            fullsync(h.fileDescriptor); try h.close()
            summen.append((s.finalize().map { String(format: "%02x", $0) }.joined(), datei))
        }
        try schreibe("kopf_1MiB.bin") { w in try v.strome([Ext(start: 0, anzahl: UInt32(MiB / v.blockSize))], logical: MiB, w) }
        try schreibe("ende_1MiB.bin") { w in
            guard let o = Optional(ende - MiB), o % v.blockSize == 0 else { throw AppFehler.sicherung("Volumeende nicht blockausgerichtet") }
            try v.strome([Ext(start: UInt32(o / v.blockSize), anzahl: UInt32(MiB / v.blockSize))], logical: MiB, w)
        }
        var forksJSON: [String: Any] = [:]
        for p in plan {
            forksJSON[p.name] = ["datei": p.name + ".bin", "fileID": p.id, "logicalSize": p.fork.logical, "totalBlocks": p.fork.blocks,
                                 "extents": p.ext.map { ["startBlock": $0.start, "blockCount": $0.anzahl, "volumeOffset": UInt64($0.start) * v.blockSize] }]
            try schreibe(p.name + ".bin") { w in try v.strome(p.ext, logical: p.fork.logical, w) }
        }
        let meta: [String: Any] = ["blockSize": v.blockSize, "quelle": quelle, "basisoffset": 0, "volumeEnde": ende,
                                   "alternateVHSignatur": String(decoding: alt, as: UTF8.self), "zeit": jetztText(jetzt),
                                   "kopf": ["datei": "kopf_1MiB.bin", "volumeOffset": 0, "bytes": MiB],
                                   "ende": ["datei": "ende_1MiB.bin", "volumeOffset": ende - MiB, "bytes": MiB], "forks": forksJSON]
        let mj = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try schreibe("extents.json") { w in w([UInt8](mj)) }
        try Data(summen.map { "\($0.0)  \($0.1)\n" }.joined().utf8).write(to: URL(fileURLWithPath: teil + "/SHA256SUMS"))
        if let h = FileHandle(forWritingAtPath: teil + "/SHA256SUMS") { fullsync(h.fileDescriptor); try h.close() }
        vorPruefung?(teil)   // Testhaken: Verfaelschung zwischen Schreiben und Pruefen
        let probleme = sicherungPruefen(ordner: teil)
        if !probleme.isEmpty { throw AppFehler.sicherung("Pruefsummen der Sicherung stimmen nicht: " + probleme.joined(separator: "; ")) }
        try fm.moveItem(atPath: teil, toPath: endgueltig)
        let dfd = open(ort, O_RDONLY); if dfd >= 0 { fullsync(dfd); close(dfd) }
    } catch {
        try? fm.removeItem(atPath: teil)
        throw error
    }
    try sicherungenAufraeumen(ort: ort, uuid: uuid, behalte: anzahl)
    let groesse = plan.reduce(0) { $0 + $1.fork.logical } + 2 * MiB
    return SicherungsErgebnis(ordner: endgueltig, bytes: groesse, dateien: summenAnzahl(endgueltig))
}

private func summenAnzahl(_ o: String) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: o).count) ?? 0 }

/// Eigene Sicherungsordner dieser UUID (Namensmuster UUID_yyyyMMdd-HHmmss UND Marker-Datei), alt -> neu.
public func eigeneSicherungen(ort: String, uuid: String) -> [String] {
    let fm = FileManager.default
    let namen = ((try? fm.contentsOfDirectory(atPath: ort)) ?? []).filter {
        $0.hasPrefix(uuid.uppercased() + "_") && !$0.hasSuffix(".partial") && fm.fileExists(atPath: ort + "/" + $0 + "/" + markerName)
    }
    return namen.sorted()
}

/// Loescht die aeltesten eigenen Sicherungen ueber `behalte` (mindestens 1 bleibt). Fremde Ordner ohne Marker bleiben immer unberuehrt.
func sicherungenAufraeumen(ort: String, uuid: String, behalte: Int) throws {
    let fm = FileManager.default
    for n in (try? fm.contentsOfDirectory(atPath: ort)) ?? [] where n.hasPrefix(uuid.uppercased() + "_") && n.hasSuffix(".partial") && fm.fileExists(atPath: ort + "/" + n + "/" + markerName) {
        try? fm.removeItem(atPath: ort + "/" + n)
    }
    let liste = eigeneSicherungen(ort: ort, uuid: uuid)
    let n = max(behalte, 1)
    if liste.count > n { for alt in liste.prefix(liste.count - n) { try fm.removeItem(atPath: ort + "/" + alt) } }
}
