import CryptoKit
import Foundation

/// Sicherung zurueckspielen (Port von tools/hfs_meta_restore.py). Nur fuer AUSGEHAENGTE Volumes.
public let maxSchreibenJeBefehl = 524288      // Drobo-Grenze je Schreibbefehl
public let standardSchreiben = 262144
let restoreChunk = 4 * Int(MiB)

public struct RestoreBereich: Equatable { public var label: String; public var datei: String; public var fpos: UInt64; public var voff: UInt64; public var n: UInt64 }

public struct RestoreProbe {
    public enum Zustand: String { case vorher, fremd }
    public var plan: [RestoreBereich] = []
    public var abweichend: [(label: String, abweichend: Int, von: Int)] = []
    public var gesamt = 0
    public var zustand: Zustand = .fremd
    public var ende: UInt64 = 0
    /// Anzeige: je Bereich Zahl abweichender 4-MiB-Bloecke.
    public var text: String {
        abweichend.map { "\($0.label): \($0.abweichend) von \($0.von)" }.joined(separator: "\n") + "\nabweichende Bloecke gesamt: \(gesamt)"
    }
}

private func lesenSums(_ d: String) throws -> [String: String] {
    guard let t = FileManager.default.contents(atPath: d + "/SHA256SUMS").map({ String(decoding: $0, as: UTF8.self) }) else { throw AppFehler.sicherung("SHA256SUMS nicht lesbar -- nichts geschrieben") }
    var m: [String: String] = [:]
    for z in t.split(separator: "\n") { let p = z.components(separatedBy: "  "); if p.count == 2 { m[p[1]] = p[0] } }
    return m
}

/// Plan: Forks zuerst, Kopf/Ende zuletzt; alles 4096-ausgerichtet, sonst Abbruch.
func restorePlan(_ d: String, _ meta: [String: Any], _ sums: [String: String], ende: UInt64) throws -> [RestoreBereich] {
    guard let bs = (meta["blockSize"] as? NSNumber)?.uint64Value, let forks = meta["forks"] as? [String: [String: Any]],
          let kopf = meta["kopf"] as? [String: Any], let end = meta["ende"] as? [String: Any] else { throw AppFehler.sicherung("extents.json unvollstaendig -- nichts geschrieben") }
    var plan: [RestoreBereich] = []
    for name in forks.keys.sorted() {
        let f = forks[name]!
        var left = (f["logicalSize"] as! NSNumber).uint64Value, fpos: UInt64 = 0
        for e in f["extents"] as! [[String: Any]] {
            let count = (e["blockCount"] as! NSNumber).uint64Value
            let part = min(count * bs, left)
            if part > 0 { plan.append(RestoreBereich(label: "\(name) ext \((e["startBlock"] as! NSNumber).uint64Value)+\(count)", datei: f["datei"] as! String, fpos: fpos, voff: (e["volumeOffset"] as! NSNumber).uint64Value, n: part)) }
            fpos += part; left -= part
        }
        if left > 0 { throw AppFehler.sicherung("\(name): Extents decken logicalSize nicht -- nichts geschrieben") }
    }
    let kb = (kopf["bytes"] as! NSNumber).uint64Value, eb = (end["bytes"] as! NSNumber).uint64Value
    plan.append(RestoreBereich(label: "kopf", datei: kopf["datei"] as! String, fpos: 0, voff: (kopf["volumeOffset"] as! NSNumber).uint64Value, n: kb))
    guard ende >= eb else { throw AppFehler.sicherung("Volumeende unplausibel -- nichts geschrieben") }
    plan.append(RestoreBereich(label: "ende", datei: end["datei"] as! String, fpos: 0, voff: ende - eb, n: eb))
    for b in plan {
        guard sums[b.datei] != nil else { throw AppFehler.sicherung("\(b.label): \(b.datei) fehlt in SHA256SUMS -- nichts geschrieben") }
        let groesse = ((try? FileManager.default.attributesOfItem(atPath: d + "/" + b.datei)[.size]) as? NSNumber)?.uint64Value ?? 0
        if groesse < b.fpos + b.n { throw AppFehler.sicherung("\(b.label): \(b.datei) zu kurz -- nichts geschrieben") }
        if b.voff % 4096 != 0 || b.n % 4096 != 0 { throw AppFehler.sicherung("\(b.label): Offset \(b.voff) / Laenge \(b.n) nicht 4096-ausgerichtet -- nichts geschrieben") }
    }
    return plan
}

private let hfsSig: [[UInt8]] = [[0x48, 0x2B], [0x48, 0x58]]

/// Geraet eingehaengt/attacht? Grund oder nil.
func eingehaengtGrund(_ geraet: String) -> String? {
    var st = stat()
    if stat(geraet, &st) == 0, st.st_mode & S_IFMT == S_IFREG {
        let (_, info) = ausfuehren("/usr/bin/hdiutil", ["info"]); let real = URL(fileURLWithPath: geraet).resolvingSymlinksInPath().path
        return info.split(separator: "\n").contains { $0.hasPrefix("image-path") && [geraet, real].contains($0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "") } ? "Abbild ist attacht (hdiutil info)" : nil
    }
    let block = geraet.replacingOccurrences(of: "/rdisk", with: "/disk")
    for (dev, e) in einhaengungen() where dev == block || dev.hasPrefix(block + "s") || dev == geraet { return "eingehaengt: \(dev) auf \(e.ort)" }
    return nil
}

/// Gemeinsame Pruefungen vor Probelauf und Ausfuehren; liefert Meta, Plan und Volumeende.
private func restoreVorbereiten(geraet: String, sicherung d: String, uuid: String?) throws -> (meta: [String: Any], plan: [RestoreBereich], ende: UInt64, sums: [String: String]) {
    let sums = try lesenSums(d)
    let probleme = sicherungPruefen(ordner: d)
    if !probleme.isEmpty { throw AppFehler.sicherung("Sicherung stimmt nicht mit SHA256SUMS: " + probleme.joined(separator: "; ") + " -- nichts geschrieben") }
    guard let md = FileManager.default.contents(atPath: d + "/extents.json"), let meta = try JSONSerialization.jsonObject(with: md) as? [String: Any],
          let bs = (meta["blockSize"] as? NSNumber)?.uint64Value, let vEnde = (meta["volumeEnde"] as? NSNumber)?.uint64Value, (meta["basisoffset"] as? NSNumber)?.intValue == 0
    else { throw AppFehler.sicherung("extents.json nicht lesbar oder Basisoffset != 0 -- nichts geschrieben") }
    if let u = uuid, !(d as NSString).lastPathComponent.uppercased().hasPrefix(u.uppercased() + "_") { throw AppFehler.sicherung("Sicherung gehoert zu einem anderen Volume -- nichts geschrieben") }
    // Sicherungskopf/-ende
    var fehler: [String] = []
    let kopf = (try? Data(contentsOf: URL(fileURLWithPath: d + "/kopf_1MiB.bin")).prefix(2048)).map { [UInt8]($0) } ?? []
    let endeDatei = (try? Data(contentsOf: URL(fileURLWithPath: d + "/ende_1MiB.bin"))).map { [UInt8]($0) } ?? []
    guard kopf.count == 2048, endeDatei.count >= 1024 else { throw AppFehler.sicherung("Kopf/Ende der Sicherung nicht lesbar -- nichts geschrieben") }
    if !hfsSig.contains(Array(kopf[1024..<1026])) { fehler.append("Signatur im Sicherungskopf ist nicht H+/HX") }
    else if UInt64(be32(kopf, 1064)) != bs { fehler.append("blockSize im Sicherungs-VH != extents.json") }
    let altSig = Array(endeDatei[(endeDatei.count - 1024)..<(endeDatei.count - 1022)])
    if altSig != Array(((meta["alternateVHSignatur"] as? String) ?? "").utf8) || !hfsSig.contains(altSig) { fehler.append("Signatur im Sicherungsende passt nicht") }
    if !fehler.isEmpty { throw AppFehler.sicherung("Sicherung inkonsistent -- nichts geschrieben: " + fehler.joined(separator: "; ")) }
    // Geraet: Groesse/Ende, Signaturen, blockSize, Volume-Kennung (finderInfo)
    let fd = open(geraet, O_RDONLY)
    guard fd >= 0 else { if errno == EACCES || errno == EPERM { throw Fehler.keinZugriff(geraet) }; throw AppFehler.sicherung("\(geraet) nicht lesbar: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    let vh = try rohLies(fd, 1024, 512)
    guard vh.count == 512 else { throw AppFehler.sicherung("Geraet: Header nicht lesbar -- nichts geschrieben") }
    var st = stat(); fstat(fd, &st)
    var ende = vEnde
    if st.st_mode & S_IFMT == S_IFREG { ende = UInt64(st.st_size) }
    guard ende == vEnde else { throw AppFehler.sicherung("Geraet: Volumeende \(ende) != Sicherung \(vEnde) (anderes Geraet?) -- nichts geschrieben") }
    let alt = try rohLies(fd, ende - 1024, 512)
    for (n, v) in [("primaeren", vh), ("alternativen", alt)] {
        if v.count < 512 || !hfsSig.contains(Array(v[0..<2])) { fehler.append("Geraet: Signatur im \(n) VH nicht H+/HX") }
        else if UInt64(be32(v, 40)) != bs { fehler.append("Geraet: blockSize im \(n) VH != Sicherung") }
    }
    if alt.count >= 2, Array(alt[0..<2]) != altSig { fehler.append("Geraet: Signatur im alternativen VH != Sicherung") }
    if vh.count == 512, Array(vh[104..<112]) != Array(kopf[1024 + 104..<1024 + 112]) { fehler.append("Geraet: Volume-Kennung (finderInfo) weicht von der Sicherung ab -- falsches Volume") }
    if !fehler.isEmpty { throw AppFehler.sicherung("Geraet passt nicht zur Sicherung -- nichts geschrieben: " + fehler.joined(separator: "; ")) }
    let plan = try restorePlan(d, meta, sums, ende: ende)
    return (meta, plan, ende, sums)
}

private func vergleich(_ fd: Int32, _ d: String, _ b: RestoreBereich) throws -> (abw: Int, bloecke: Int) {
    guard let f = FileHandle(forReadingAtPath: d + "/" + b.datei) else { throw AppFehler.sicherung("\(b.datei) nicht lesbar") }
    defer { try? f.close() }
    try f.seek(toOffset: b.fpos)
    var abw = 0, bl = 0, done: UInt64 = 0
    while done < b.n {
        let k = Int(min(UInt64(restoreChunk), b.n - done))
        let want = [UInt8](try f.read(upToCount: k) ?? Data())
        let have = try rohLies(fd, b.voff + done, k)
        bl += 1; if have != want { abw += 1 }
        done += UInt64(k)
    }
    return (abw, bl)
}

/// Probelauf: schreibt nie (O_RDONLY). Identitaet geprueft, je Bereich Zahl abweichender 4-MiB-Bloecke.
public func zurueckspielenProbe(geraet: String, sicherung: String, uuid: String? = nil) throws -> RestoreProbe {
    let v = try restoreVorbereiten(geraet: geraet, sicherung: sicherung, uuid: uuid)
    let fd = open(geraet, O_RDONLY); guard fd >= 0 else { throw AppFehler.sicherung("\(geraet) nicht lesbar") }
    defer { close(fd) }
    var p = RestoreProbe(); p.plan = v.plan; p.ende = v.ende
    for b in v.plan { let r = try vergleich(fd, sicherung, b); p.abweichend.append((b.label, r.abw, r.bloecke)); p.gesamt += r.abw }
    p.zustand = p.gesamt == 0 ? .vorher : .fremd
    return p
}

/// Zurueckschreiben: nur ausgehaengt, je Befehl <= schreibgroesse (<= 524288, durch 4096 teilbar), fsync, Zuruecklesen + Vergleich.
/// Rueckgabe: Bereiche mit Abweichung nach dem Zuruecklesen (leer = alles gleich).
/// `erzwinge`: das Geraet darf vom Sicherungsstand abweichen (der Normalfall nach einer Schreibsitzung); die Aufrufer holen vorher die ausdrueckliche Bestaetigung.
@discardableResult
public func zurueckspielenAusfuehren(geraet: String, sicherung: String, uuid: String? = nil, schreibgroesse: Int = standardSchreiben,
                                     erzwinge: Bool = false, schreibHaken: ((Int) -> Void)? = nil) throws -> [String] {
    guard schreibgroesse > 0, schreibgroesse % 4096 == 0, schreibgroesse <= maxSchreibenJeBefehl else {
        throw AppFehler.sicherung("Schreibgroesse \(schreibgroesse): positiv, durch 4096 teilbar, hoechstens \(maxSchreibenJeBefehl) -- nichts geschrieben")
    }
    let v = try restoreVorbereiten(geraet: geraet, sicherung: sicherung, uuid: uuid)
    if let g = eingehaengtGrund(geraet) { throw AppFehler.sicherung("\(g) -- nichts geschrieben") }
    let rfd = open(geraet, O_RDONLY); guard rfd >= 0 else { throw AppFehler.sicherung("\(geraet) nicht lesbar") }
    var gesamt = 0
    for b in v.plan { gesamt += try vergleich(rfd, sicherung, b).abw }
    close(rfd)
    if gesamt > 0 && !erzwinge { throw AppFehler.sicherung("Geraet weicht von der Sicherung ab und Ueberschreiben ist nicht bestaetigt -- nichts geschrieben") }
    let wfd = open(geraet, O_RDWR)
    guard wfd >= 0 else { if errno == EACCES || errno == EPERM { throw Fehler.keinZugriff(geraet) }; throw AppFehler.sicherung("\(geraet) nicht schreibbar: \(String(cString: strerror(errno)))") }
    do {
        for b in v.plan {
            guard let f = FileHandle(forReadingAtPath: sicherung + "/" + b.datei) else { throw AppFehler.sicherung("\(b.datei) nicht lesbar") }
            try f.seek(toOffset: b.fpos)
            var done: UInt64 = 0
            while done < b.n {
                let k = Int(min(UInt64(schreibgroesse), b.n - done))
                let buf = [UInt8](try f.read(upToCount: k) ?? Data())
                guard buf.count == k else { try? f.close(); throw AppFehler.sicherung("\(b.label): Sicherungsdatei zu kurz -- Abbruch") }
                schreibHaken?(k)
                let w = buf.withUnsafeBytes { pwrite(wfd, $0.baseAddress!, k, off_t(b.voff + done)) }
                if w != k { try? f.close(); throw AppFehler.sicherung("\(b.label): Schreiben bei \(b.voff + done) fehlgeschlagen (\(String(cString: strerror(errno)))) -- Abbruch") }
                done += UInt64(k)
            }
            try f.close(); fullsync(wfd)
        }
    } catch { close(wfd); throw error }
    close(wfd)
    let fd = open(geraet, O_RDONLY); guard fd >= 0 else { throw AppFehler.sicherung("Zuruecklesen nicht moeglich") }
    defer { close(fd) }
    var fehler: [String] = []
    for b in v.plan { let r = try vergleich(fd, sicherung, b); if r.abw > 0 { fehler.append("\(b.label): \(r.abw) von \(r.bloecke) Bloecken weichen ab") } }
    return fehler
}
