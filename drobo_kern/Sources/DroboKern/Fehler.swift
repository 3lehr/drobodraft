import Foundation

public enum Modus: String { case nurlesen, schreiben }

/// Jeder Fehler hat einen festen Exit-Code und eine Meldung mit Ausweg.
public enum Fehler: Error, CustomStringConvertible {
    case eingabe(String)                    // 2
    case nichtGefunden(String)              // 10
    case eingehaengt(String)                // 11
    case keineFreigabe(String)              // 12
    case freigabeReichtNicht(String)        // 13
    case modul(String)                      // 14
    case tor([String])                      // 15
    case keinZugriff(String)                // 16
    case ortUnterHome(String)               // 17
    case mountFehlgeschlagen(String)        // 18
    case nichtEingehaengt(String)           // 19
    case aushaengenFehlgeschlagen(String)   // 20
    case freigabeDatei(String)              // 21

    public var code: Int32 {
        switch self {
        case .eingabe: return 2
        case .nichtGefunden: return 10
        case .eingehaengt: return 11
        case .keineFreigabe: return 12
        case .freigabeReichtNicht: return 13
        case .modul: return 14
        case .tor: return 15
        case .keinZugriff: return 16
        case .ortUnterHome: return 17
        case .mountFehlgeschlagen: return 18
        case .nichtEingehaengt: return 19
        case .aushaengenFehlgeschlagen: return 20
        case .freigabeDatei: return 21
        }
    }

    public var description: String {
        switch self {
        case .eingabe(let s): return s
        case .nichtGefunden(let u): return "kein Volume mit UUID \(u) gefunden (Drobo angeschlossen? Kernel erkennt das Volume?)"
        case .eingehaengt(let s): return "Volume ist bereits eingehaengt: \(s). Zuerst: drobo aushaengen"
        case .keineFreigabe(let u): return "Freigabeliste hat keinen Eintrag fuer \(u). Anlegen: drobo freigabe nurlesen"
        case .freigabeReichtNicht(let s): return s
        case .modul(let s): return s
        case .tor(let l): return "Torpruefung nicht bestanden: " + l.joined(separator: "; ")
        case .keinZugriff(let d): return "keine Leseberechtigung auf \(d). Betreiber fuehrt aus: sudo chown $USER \(d) \(d.replacingOccurrences(of: "/dev/rdisk", with: "/dev/disk"))"
        case .ortUnterHome(let o): return "Einhaengeort \(o) liegt unter dem Home-Ordner (Spotlight wuerde einziehen). Ort ausserhalb waehlen, z. B. /private/tmp/drobo_mnt"
        case .mountFehlgeschlagen(let s): return "mount fehlgeschlagen: \(s)"
        case .nichtEingehaengt(let u): return "Volume \(u) ist nicht eingehaengt"
        case .aushaengenFehlgeschlagen(let s): return "Aushaengen fehlgeschlagen: \(s)"
        case .freigabeDatei(let s): return "Freigabeliste: \(s)"
        }
    }
}
