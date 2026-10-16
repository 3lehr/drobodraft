import Foundation

private let vhFelder: [(String, Int, Int)] = [("signature", 0, 2), ("version", 2, 2), ("attributes", 4, 4), ("lastMountedVersion", 8, 4),
    ("journalInfoBlock", 12, 4), ("createDate", 16, 4), ("modifyDate", 20, 4), ("backupDate", 24, 4), ("checkedDate", 28, 4),
    ("fileCount", 32, 4), ("folderCount", 36, 4), ("blockSize", 40, 4), ("totalBlocks", 44, 4), ("freeBlocks", 48, 4),
    ("nextAllocation", 52, 4), ("rsrcClumpSize", 56, 4), ("dataClumpSize", 60, 4), ("nextCatalogID", 64, 4), ("writeCount", 68, 4),
    ("encodingsBitmap", 72, 8), ("finderInfo", 80, 32), ("allocationFile", 112, 80), ("extentsFile", 192, 80),
    ("catalogFile", 272, 80), ("attributesFile", 352, 80), ("startupFile", 432, 80)]
private let erlaubt: Set<String> = ["attributes", "lastMountedVersion", "modifyDate", "freeBlocks", "nextAllocation", "writeCount"]
private let zaehler: Set<String> = erlaubt.subtracting(["attributes"]).union(["fileCount", "folderCount", "nextCatalogID", "checkedDate"])

/// Werkzeugordner mit hfs_mark_clean.py fuer die optionale Katalog-Tiefenpruefung (Umgebung DROBO_WERKZEUGE, sonst bekannter Ort); nil = nicht verfuegbar.
public func werkzeugOrdner() -> String? {
    let kand = [Kern.umgebung("DROBO_WERKZEUGE"), "/Volumes/daten/Begod2026/drobo-nas/apps/drobo-nas/tools"].compactMap { $0 }
    return kand.first { FileManager.default.fileExists(atPath: $0 + "/hfs_mark_clean.py") }
}

/// Nachpruefung eines AUSGEHAENGTEN Volumes (nur lesend): Header-Bits beider VH, Journal leer, Ersatz-VH, freeBlocks == Bitmap; optional Katalog-Tiefenpruefung.
/// Swift-nativ wie hfs_mark_clean.py --nur-pruefen ohne den Katalog-Lauf; der Katalog-Lauf (rund 1500 Zeilen Python) bleibt Python und ist optional.
public func nachpruefung(pfad: String, partitionsgroesse: UInt64? = nil, tief: Bool = true) throws -> PruefErgebnis {
    var r = PruefErgebnis(); r.zeit = jetztText()
    let v = try HFSLeser(pfad: pfad)
    let ende = try v.volumeEnde(partitionsgroesse: partitionsgroesse)
    let al = try v.lies(ende - 1024, 512)
    guard al.count == 512 else { r.probleme.append("Ersatz-Volume-Header nicht lesbar"); return r }
    let p = v.vh
    // Primaerer VH: Bits + Journal wie die Torpruefung vor dem Einhaengen
    do { r.probleme += try torpruefung(pfad: pfad).probleme } catch let e as Fehler { r.probleme.append(e.description) }
    let ap = be32(p, 4), aa = be32(al, 4)
    for (n, a) in [("primaeren", ap), ("alternativen", aa)] {
        if a & 0x800 != 0 { r.probleme.append("0x800 (inkonsistent) im \(n) Header gesetzt") }
        if a & 0x4000 != 0 { r.probleme.append("0x4000 im \(n) Header gesetzt") }
    }
    let diff = vhFelder.filter { Array(p[$0.1..<$0.1 + $0.2]) != Array(al[$0.1..<$0.1 + $0.2]) }.map { $0.0 }
    let veraltet = diff.filter { zaehler.contains($0) }
    if !veraltet.isEmpty { r.hinweise.append("Ersatz-Header veraltet in: " + veraltet.joined(separator: ", ") + " (erwartbar, primaerer Header gilt)") }
    let struktur = diff.filter { !erlaubt.contains($0) && !zaehler.contains($0) }
    if !struktur.isEmpty { r.probleme.append("primaerer und alternativer Header weichen ab in: " + struktur.joined(separator: ", ")) }
    // freeBlocks gegen Allocation-Bitmap
    do {
        let ext = try v.vollExtents("allocation"); let f = v.forks["allocation"]!
        let total = UInt64(v.totalBlocks); let noetig = (total + 7) / 8
        if f.logical < noetig || ext.reduce(0, { $0 + UInt64($1.anzahl) }) * v.blockSize < noetig { throw AppFehler.pruefung("Allocation-Datei kleiner als totalBlocks/8") }
        var gesetzt: UInt64 = 0; var byte: UInt64 = 0
        try v.strome(ext, logical: noetig) { b in
            for x in b {
                var m = x
                if (byte + 1) * 8 > total { let gueltig = Int(total - byte * 8); m &= gueltig <= 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - gueltig)) }
                gesetzt += UInt64(m.nonzeroBitCount); byte += 1
            }
        }
        let frei = total - gesetzt
        if UInt64(v.freeBlocks) != frei { r.probleme.append("freeBlocks im Header (\(v.freeBlocks)) != Bitmap-frei (\(frei))") }
    } catch { r.probleme.append("Bitmap nicht auswertbar: \(error)") }
    // Katalog-Tiefenpruefung (optional)
    if tief, r.probleme.isEmpty {
        if let w = werkzeugOrdner(), FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
            let py = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") ? "/opt/homebrew/bin/python3" : "/usr/bin/python3"
            let (rc, out) = ausfuehren(py, ["-I", w + "/hfs_mark_clean.py", pfad, "--ende", String(ende), "--nur-pruefen"])
            if rc == 0 && out.contains("PRUEFUNG OK") { r.tiefe = .ok }
            else { r.tiefe = .fehler; r.probleme.append("Katalogpruefung: " + (out.components(separatedBy: "PRUEFUNG FEHLER:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? out.suffix(300).description)) }
        } else { r.hinweise.append("Katalogpruefung nicht verfuegbar (nur Header, Journal und Bitmap geprueft)") }
    }
    r.ok = r.probleme.isEmpty
    return r
}

/// Gesamt/Belegt aus dem primaeren Volume-Header (nur lesend).
public func belegungAusHeader(pfad: String) throws -> Belegung {
    let v = try HFSLeser(pfad: pfad)
    let gesamt = UInt64(v.totalBlocks) * v.blockSize
    return Belegung(gesamt: gesamt, belegt: gesamt - UInt64(v.freeBlocks) * v.blockSize, zeit: jetztText())
}
