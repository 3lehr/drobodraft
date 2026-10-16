import CryptoKit
import Foundation

public struct WegsichernBericht: Equatable {
    public var kopiert = 0, uebersprungen = 0, geprueft = 0, bytes: UInt64 = 0
    public var fehler: [String] = []
    public var abgebrochen = false
    public var ok: Bool { fehler.isEmpty && !abgebrochen }
    public var text: String {
        "\(kopiert) kopiert, \(uebersprungen) unveraendert uebersprungen, \(geprueft) per SHA-256 geprueft, \(bytes) Byte" +
        (fehler.isEmpty ? "" : ", \(fehler.count) Fehler: " + fehler.prefix(5).joined(separator: "; ")) + (abgebrochen ? ", abgebrochen" : "")
    }
}

func sha256Pfad(_ p: String) throws -> String { try sha256Datei(p) }

func mtime(_ s: stat) -> Double { Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec) / 1e9 }

/// Ordner wegsichern, inkrementell: gleiche Groesse und mtime (+-1 s, HFS+ rundet) = uebersprungen; sonst kopieren (copyfile ALL: Daten, Attribute, Ressource-Fork)
/// in eine Teildatei, SHA-256 der Kopie gegen die Quelle, erst dann umbenennen. Die Quelle wird nur gelesen, nie veraendert oder geloescht.
public func ordnerWegsichern(quelle: String, ziel: String, verboten: [String] = [], fortschritt: ((String) -> Void)? = nil,
                             abbrechen: () -> Bool = { false }) throws -> WegsichernBericht {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: quelle, isDirectory: &isDir), isDir.boolValue else { throw AppFehler.wegsichern("Quellordner \(quelle) existiert nicht") }
    let q = Kern.aufgeloest(quelle), z = Kern.aufgeloest(ziel)
    if z == q || z.hasPrefix(q + "/") { throw AppFehler.wegsichern("Zielordner liegt in der Quelle -- anderes Ziel waehlen") }
    for v in verboten.map({ Kern.aufgeloest($0) }) where z == v || z.hasPrefix(v + "/") {
        throw AppFehler.wegsichern("Zielordner liegt auf der Drobo (\(v)) -- ein anderes Laufwerk waehlen")
    }
    let wurzel = z + "/" + (q as NSString).lastPathComponent
    try fm.createDirectory(atPath: wurzel, withIntermediateDirectories: true)
    var b = WegsichernBericht()
    guard let en = fm.enumerator(atPath: q) else { throw AppFehler.wegsichern("Quellordner nicht lesbar") }
    for case let rel as String in en {
        if abbrechen() { b.abgebrochen = true; break }
        let s = q + "/" + rel, d = wurzel + "/" + rel
        var st = stat(); guard lstat(s, &st) == 0 else { b.fehler.append("\(rel): \(String(cString: strerror(errno)))"); continue }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        case S_IFLNK:
            if let t = try? fm.destinationOfSymbolicLink(atPath: s) {
                if (try? fm.destinationOfSymbolicLink(atPath: d)) != t { try? fm.removeItem(atPath: d); try? fm.createSymbolicLink(atPath: d, withDestinationPath: t); b.kopiert += 1 } else { b.uebersprungen += 1 }
            }
        case S_IFREG:
            var ds = stat()
            if lstat(d, &ds) == 0, ds.st_size == st.st_size, abs(mtime(ds) - mtime(st)) < 1.0 { b.uebersprungen += 1; continue }
            fortschritt?(rel)
            let teil = d + ".drobo-teil"
            try? fm.removeItem(atPath: teil)
            if copyfile(s, teil, nil, copyfile_flags_t(COPYFILE_ALL)) != 0 { b.fehler.append("\(rel): Kopieren: \(String(cString: strerror(errno)))"); try? fm.removeItem(atPath: teil); continue }
            do {
                let a = try sha256Pfad(s), c = try sha256Pfad(teil)
                guard a == c else { b.fehler.append("\(rel): SHA-256 der Kopie weicht von der Quelle ab"); try? fm.removeItem(atPath: teil); continue }
                try? fm.removeItem(atPath: d)
                try fm.moveItem(atPath: teil, toPath: d)
                b.kopiert += 1; b.geprueft += 1; b.bytes += UInt64(st.st_size)
            } catch { b.fehler.append("\(rel): \(error)"); try? fm.removeItem(atPath: teil) }
        default: b.uebersprungen += 1
        }
    }
    return b
}
