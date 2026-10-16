import Foundation

/// Fehler der App-Schicht (Sicherung, Pruefung, Wegsichern, Tempotest). Eigene Datei, damit Fehler.swift (auch im Hilfsdienst) unveraendert bleibt.
public enum AppFehler: Error, CustomStringConvertible {
    case sicherungOrt(String)       // 30
    case sicherungPlatz(String)     // 31
    case sicherung(String)          // 32
    case pruefung(String)           // 33
    case nurAnzeige(String)         // 34
    case wegsichern(String)         // 35
    case tempotest(String)          // 36

    public var code: Int32 {
        switch self {
        case .sicherungOrt: return 30
        case .sicherungPlatz: return 31
        case .sicherung: return 32
        case .pruefung: return 33
        case .nurAnzeige: return 34
        case .wegsichern: return 35
        case .tempotest: return 36
        }
    }
    public var description: String {
        switch self {
        case .sicherungOrt(let s), .sicherungPlatz(let s), .sicherung(let s), .pruefung(let s), .nurAnzeige(let s), .wegsichern(let s), .tempotest(let s): return s
        }
    }
}
