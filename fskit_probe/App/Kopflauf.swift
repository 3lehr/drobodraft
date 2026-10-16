import DroboKern
import Foundation
import ServiceManagement

// Kopfaufrufe ohne Fenster (Pruefbarkeit): --helfer-status | --helfer-registrieren | --helfer-neu | --zugriff-status | --zugriff-anfragen | --zustand | --ui-text
let helferPlist = "de.begod.drobohelper.plist"

func helferStatusText() -> String {
    switch SMAppService.daemon(plistName: helferPlist).status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unbekannt"
    }
}

func helferRegistrieren() -> String {
    do { try SMAppService.daemon(plistName: helferPlist).register(); return "register ok" }
    catch { return "register Fehler: \(error)" }
}

/// Prueft, ob DIESER Prozess (die App) das Roh-Geraet der Partition oeffnen darf. Nur O_RDONLY|O_NONBLOCK, sofort close, nie lesen/schreiben.
func zugriffOeffnen(_ uuid: String) -> String {
    guard let m = finden(uuid: uuid) else { return "kein Volume mit UUID \(uuid) gefunden" }
    guard m.bsd.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else { return "\(m.bsd) ist keine Partition (abgelehnt)" }
    let fd = open(m.rohgeraet, O_RDONLY | O_NONBLOCK)
    if fd < 0 { let e = errno; return "open \(m.rohgeraet): errno=\(e) (\(String(cString: strerror(e))))" }
    close(fd)
    return "open \(m.rohgeraet): ok"
}

func kopfOpt(_ n: String) -> String? { let a = CommandLine.arguments; if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return nil }

/// Gibt true zurueck, wenn ein Kopfaufruf bearbeitet wurde (Prozess endet dann).
func kopflauf() -> Bool {
    let a = CommandLine.arguments
    let ablage = Datenablage()
    let u = kopfOpt("--uuid") ?? ablage.einstellungen().drobos.first?.uuid ?? vorgabeUUID
    if a.contains("--zugriff-anfragen") || a.contains("--zugriff-status") {
        if a.contains("--zugriff-anfragen") { print("macOS fragt jetzt ggf. nach Zugriff auf Wechseldatentraeger -> Erlauben") }
        print(zugriffOeffnen(u)); return true
    }
    if a.contains("--helfer-neu") { try? SMAppService.daemon(plistName: helferPlist).unregister(); print("unregister status=\(helferStatusText())") }
    if a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print(helferRegistrieren()) }
    if a.contains("--helfer-status") || a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print("status=\(helferStatusText())"); return true }
    if a.contains("--zustand") {
        for d in ablage.einstellungen().drobos {
            var k = Kern(uuid: d.uuid); k.ablage = ablage
            print("\(d.name) [\(d.rolle.rawValue)] \(d.uuid): " + ((try? k.zustand(mitFreigabe: false).kurz) ?? "unbekannt"))
        }
        return true
    }
    return false
}
