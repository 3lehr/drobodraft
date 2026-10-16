import Darwin
import Foundation
import IOKit

/// Physischer Platz der Drobo (Thin Provisioning: HFS meldet mehr frei als die Platten haben; gemessen 6,72 TB HFS gegen 4,25 TB physisch).
/// Quelle: "DroboStatus" des Dext (alle 60 s) oberhalb des eigenen Blockgeraets, gelesen mit dem gemeinsamen Decoder (DroboKern/DroboStatus.swift).
/// Pruefbau TEST_PHYSISCH: dieselbe Property als Datei physisch.plist im Container (Testabbilder haben keinen Dext).
/// Verfuegbar = physisch frei − seit dem Messzeitpunkt aufs Geraet geschriebene Bytes (lifs_dev_stats.bytes: Daten, Metadaten, Journal; Ueberschreiben zaehlt mit).
/// Ohne Daten: keine Aussage (nil), nur HFS-Regeln.
#if TEST_PHYSISCH
let physischBau = 1
#else
let physischBau = 0
#endif

final class Platz {
    private let l = NSLock()
    private let bsd: String
    private let reserveFest: UInt64?
    private var frei: UInt64?, geschuetzt: UInt64 = 0, messZeit = Date.distantPast, basis: UInt64 = 0
    /// (Zeit, Geraetebytes) je Auffrischung; die erste (Mount) bleibt, damit eine Messung von vor der letzten Probe nie zu wenig abzieht.
    private var proben: [(Date, UInt64)] = []
    private var abgefragt = Date.distantPast
    private(set) var gesperrt = 0

    init(bsd: String, reserve: UInt64?) {
        self.bsd = bsd; reserveFest = reserve
        proben = [(Date(), lifs_dev_stats.bytes)]
        hfsLog.notice("REGISTRY \(Platz.registryWeg(bsd), privacy: .public)")
    }

    /// Messung Sandbox (Plan „Physischer Füllstand“): Klassen vom Medium aufwaerts, je Ebene ob eine Property lesbar ist.
    static func registryWeg(_ bsd: String) -> String {
        var cur = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard cur != IO_OBJECT_NULL else { return "bsd=\(bsd) kein Registry-Eintrag (Sandbox oder unbekannt)" }
        var teile: [String] = []
        for _ in 0..<12 {
            var name = [CChar](repeating: 0, count: 128); IOObjectGetClass(cur, &name)
            let mx = IORegistryEntryCreateCFProperty(cur, "IOMaximumByteCountRead" as CFString, kCFAllocatorDefault, 0) != nil
            let ds = IORegistryEntryCreateCFProperty(cur, "DroboStatus" as CFString, kCFAllocatorDefault, 0) != nil
            teile.append("\(String(cString: name))\(mx ? "[maxRead]" : "")\(ds ? "[DroboStatus]" : "")")
            var parent: io_registry_entry_t = 0
            let r = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
            IOObjectRelease(cur)
            guard r == KERN_SUCCESS else { break }
            cur = parent
        }
        return "bsd=\(bsd) " + teile.joined(separator: " < ")
    }

    private func quelle() -> DroboStatus? {
        #if TEST_PHYSISCH
        return (NSDictionary(contentsOfFile: NSHomeDirectory() + "/physisch.plist") as? [String: Any]).flatMap(decodiereDroboStatus)
        #else
        return liesDroboStatus(bsd: bsd)
        #endif
    }

    /// unter l: hoechstens alle 10 s neu lesen; neuere Messung -> Abzug ab der letzten Probe, die nicht nach dem Messzeitpunkt liegt.
    private func auffrischen() {
        let jetzt = Date()
        guard jetzt.timeIntervalSince(abgefragt) >= 10 else { return }
        abgefragt = jetzt
        proben.append((jetzt, lifs_dev_stats.bytes)); if proben.count > 64 { proben.remove(at: 1) }
        guard let s = quelle(), let k = s.kapazitaet, s.zeit > messZeit else { return }
        frei = k.frei; geschuetzt = k.gesamtGeschuetzt; messZeit = s.zeit
        basis = (proben.last { $0.0 <= s.zeit } ?? proben[0]).1
    }

    /// Physisch verfuegbar (Bytes) bei jeder Abfrage neu gerechnet; nil = keine Statusdaten.
    func verfuegbar() -> UInt64? {
        l.lock(); defer { l.unlock() }
        auffrischen()
        guard let f = frei else { return nil }
        let ab = lifs_dev_stats.bytes &- basis
        return f > ab ? f - ab : 0
    }

    /// Vorgabe max(2 % von geschuetzt gesamt, 500 GB); freigabe.json "reserve_bytes" ersetzt sie.
    var reserve: UInt64 { l.lock(); defer { l.unlock() }; return reserveFest ?? max(geschuetzt / 50, 500_000_000_000) }

    /// Harter Halt vor Wachsen/Zuweisen: verfuegbar < Reserve -> ENOSPC (nur wenn `waechst()`; Ueberschreiben, Kuerzen, Loeschen bleiben erlaubt).
    /// ponytail: keine Reservierung je Befehl; parallele Schreiber koennen die Reserve um die gerade laufenden Schreibbefehle ueberholen
    /// (je Aufruf <= FSKit-Schreibgroesse, wenige MiB), nie unbegrenzt, weil jeder folgende Befehl den Zaehler sieht. Reservierung, falls das je zaehlt.
    func pruefen(_ was: String, waechst: () -> Bool) throws {
        guard let v = verfuegbar() else { return }
        let r = reserve
        guard v < r, waechst() else { return }
        l.lock(); gesperrt += 1; let n = gesperrt; l.unlock()
        if n <= 20 || n % 1000 == 0 { hfsLog.error("PLATZ-SPERRE \(was, privacy: .public): physisch verfuegbar \(v) < Reserve \(r) -> ENOSPC (Nr. \(n))") }
        throw posixError(ENOSPC)
    }

    /// Fuer die STATS-Zeile.
    var zeile: String {
        guard let v = verfuegbar() else { return "physisch=unbekannt" }
        l.lock(); defer { l.unlock() }
        return "physisch=\(v) gemessen_vor_s=\(Int(Date().timeIntervalSince(messZeit))) reserve=\(reserveFest ?? max(geschuetzt / 50, 500_000_000_000)) platz_gesperrt=\(gesperrt)"
    }
}
