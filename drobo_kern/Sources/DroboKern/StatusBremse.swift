import Foundation

/// Bremse fuer die Status-Abfrage einer Netzwerk-Drobo (eine Instanz je Drobo). Messbefund 2026-10-17: Die DroboPro haengt ihre Befehlsverarbeitung, sobald ein Befehl
/// unbeantwortet bleibt; jede weitere Abfrage im 60-s-Takt mit neuer Sitzung haelt sie dort fest und fuellt sie mit Leichen. Darum:
/// hoechstens alle 5 min, nie waehrend eingehaengt, nie zwei gleichzeitig, und nach EINER Zeitueberschreitung (oder Ablehnung durch einen anderen Rechner)
/// Pause, bis der Nutzer "Erneut pruefen" waehlt.
public final class StatusBremse: @unchecked Sendable {
    public enum Zustand: Equatable { case bereit, reagiertNicht, anderemRechner }
    public static let abstand: TimeInterval = 300
    private let lock = NSLock()
    private var _zustand = Zustand.bereit
    private var letzter: Date?
    private var laeuft = false
    public init() {}
    public var zustand: Zustand { lock.lock(); defer { lock.unlock() }; return _zustand }

    /// true = jetzt abfragen (und als laufend vermerkt; `ergebnis` danach IMMER aufrufen).
    public func darfAbfragen(eingehaengt: Bool, jetzt: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !eingehaengt, _zustand == .bereit, !laeuft else { return false }
        if let l = letzter, jetzt.timeIntervalSince(l) < Self.abstand { return false }
        laeuft = true; letzter = jetzt; return true
    }

    /// nil = gelungen. Zeitueberschreitung (Login und erster Befehl: nach 30 s, Folgebefehle: nach 10 s; siehe `ISCSISitzung.ersteZeitgrenzeNetz`) -> `reagiertNicht`; Login-Ablehnung 2/2 -> `anderemRechner`; andere Fehler (Netz weg) bremsen nur ueber den Abstand.
    public func ergebnis(_ fehler: Error?) {
        lock.lock(); defer { lock.unlock() }
        laeuft = false
        switch fehler as? ISCSIFehler {
        case .zeitueberschreitung?: _zustand = .reagiertNicht
        case .belegt?: _zustand = .anderemRechner
        default: break
        }
    }

    /// Weckphase (Suchen/Einhaengen einer schlafenden DroboPro): reserviert die Abfrage, solange sie laeuft (keine zweite Sitzung, die die Weck-Sitzung ersetzte). false = nicht moeglich.
    /// `NOT READY` waehrend der Phase ist kein Haenger; nur ein Befehl ohne Antwort oder Ablauf der 90 s (`.zeitueberschreitung`) setzt `reagiertNicht`. Danach gilt der Abstand ab jetzt.
    public func weckenBeginnen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard _zustand == .bereit, !laeuft else { return false }
        laeuft = true; return true
    }
    public func weckenEnde(_ fehler: Error?) { ergebnis(fehler); lock.lock(); if fehler == nil { letzter = Date() }; lock.unlock() }

    /// Nutzer-Aktion "Erneut pruefen": hebt die Pause auf und erlaubt die naechste Abfrage sofort.
    public func erneutPruefen() { lock.lock(); _zustand = .bereit; letzter = nil; lock.unlock() }
}
