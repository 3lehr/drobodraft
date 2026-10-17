import Foundation

/// Mit welchen Drobo-Modellen und Firmware-Staenden wurde eine Aktion bisher gemessen (nur das ist "erprobt"). Alles andere wird dem Nutzer vor der Bestaetigung als nicht erprobt gezeigt.
public struct ErprobtEintrag: Equatable {
    public let modell: String          // wie DroboStatus.modell nach normalisiere(): "5c gen3", "pro"
    public let anzeige: String         // Name fuer die Oberflaeche
    public let firmwareBuild: Int
    public let schreiben: Bool
    public let formatieren: Bool
    public let beleg: String
}

public enum ErprobtAktion { case schreiben, formatieren }

public enum ErprobtErgebnis: Equatable {
    case erprobt
    /// Erprobte Kombinationen fuer diese Aktion (Anzeige, Build), damit der Nutzer sieht, wofuer es Belege gibt.
    case nichtErprobt(erprobt: [ErprobtEintrag])
}

public let erprobteDrobos: [ErprobtEintrag] = [
    ErprobtEintrag(modell: "5c gen3", anzeige: "Drobo 5C Gen3", firmwareBuild: 50532, schreiben: true, formatieren: false, beleg: "Schreibtest 21/21, Platzsperre, Haertetest Abbilder"),
    ErprobtEintrag(modell: "pro", anzeige: "DroboPro", firmwareBuild: 22137, schreiben: true, formatieren: true, beleg: "200 MiB, md5 nach Neueinhaengen; LUN 1 formatiert und verifiziert"),
]

func normalisiere(_ modell: String) -> String {
    var m = modell.trimmingCharacters(in: .whitespaces).lowercased()
    if m.hasPrefix("drobo") { m = String(m.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    return m
}

/// Modell und Firmware-Build kommen aus Seite 0x08 (DroboStatus). Build unbekannt (nil) = nicht erprobt.
public func erprobt(modell: String, build: Int?, aktion: ErprobtAktion) -> ErprobtErgebnis {
    let fuerAktion = erprobteDrobos.filter { aktion == .schreiben ? $0.schreiben : $0.formatieren }
    if let b = build, fuerAktion.contains(where: { $0.modell == normalisiere(modell) && $0.firmwareBuild == b }) { return .erprobt }
    return .nichtErprobt(erprobt: fuerAktion)
}
