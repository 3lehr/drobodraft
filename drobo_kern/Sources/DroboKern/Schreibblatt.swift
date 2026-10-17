import Foundation

/// Welches Bestaetigungsblatt beim "Zum Schreiben einhaengen" erscheint: volles Blatt mit Sperre oder die kurze Zeile.
/// Voll beim ERSTEN Mal je Drobo und erneut, sobald sich Firmware-Build, Anschluss oder der Schreibweg der App aendert, die letzte Schreibsitzung unsauber endete
/// oder die Kombination nicht erprobt ist (dann immer). Formatieren hat immer das volle Blatt.
public let schreibwegVersion = 1      // bei JEDER Aenderung am Schreibweg (Kern, Modul, Helfer) hochzaehlen: dann erscheint das volle Blatt erneut
public let sperrSekunden = 15

/// Zuletzt bestaetigte Kombination je Drobo (Schluessel: Volume-UUID, bei Netzwerk-Drobos mit LUN).
public struct BestaetigteKombination: Codable, Equatable {
    public var build: Int?
    public var anschluss: String
    public var schreibweg: Int
    public init(build: Int?, anschluss: Anschluss, schreibweg: Int = schreibwegVersion) { self.build = build; self.anschluss = anschluss.rawValue; self.schreibweg = schreibweg }
}

public enum VollGrund: String, Equatable { case erstmals, nichtErprobt, firmware, anschluss, schreibweg, unsauber, formatieren }

public enum BlattArt: Equatable {
    case voll(VollGrund), kurz
    /// Sekunden, die "Bestaetigen" gesperrt ist.
    public var sperre: Int { if case .voll = self { return sperrSekunden }; return 0 }
}

public func schreibBlattArt(erprobt: Bool, zuletzt: BestaetigteKombination?, build: Int?, anschluss: Anschluss, schreibweg: Int = schreibwegVersion, unsauber: Bool) -> BlattArt {
    if !erprobt { return .voll(.nichtErprobt) }
    guard let z = zuletzt else { return .voll(.erstmals) }
    if z.build != build { return .voll(.firmware) }
    if z.anschluss != anschluss.rawValue { return .voll(.anschluss) }
    if z.schreibweg != schreibweg { return .voll(.schreibweg) }
    if unsauber { return .voll(.unsauber) }
    return .kurz
}

/// Restsekunden der Sperre (aufgerundet, 0...dauer); Uhr kommt von aussen (Test, Steuerung). Eine zurueckgestellte Uhr verlaengert die Sperre nie ueber `dauer`.
public func sperreRest(start: Date, dauer: Int, jetzt: Date) -> Int {
    let rest = Double(dauer) - jetzt.timeIntervalSince(start)
    return max(0, min(dauer, Int(rest.rounded(.up))))
}
