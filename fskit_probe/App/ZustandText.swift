import DroboKern
import SwiftUI

/// Oberflaechentexte zum Gesamtzustand des Kerns (der Kern liefert Faelle, hier stehen die uebersetzten Saetze).
extension Schlagzeile {
    var text: String {
        switch self {
        case .inOrdnung: return String(localized: "Alles in Ordnung")
        case .platzKnapp: return String(localized: "Platz wird knapp")
        case .platzSehrKnapp: return String(localized: "Platz ist fast aufgebraucht")
        case .plattenDefekt: return String(localized: "Eine Festplatte ist ausgefallen oder fehlt")
        case .keinePlatten: return String(localized: "Keine Festplatten eingesetzt")
        case .zuVieleFehlen: return String(localized: "Zu viele Festplatten fehlen")
        case .keineRedundanz: return String(localized: "Kein Schutz vor Festplattenausfall")
        case .redundanzWirdHergestellt: return String(localized: "Schutz wird wiederhergestellt")
        case .dateisystemAuffaellig: return String(localized: "Das Dateisystem ist auffällig")
        case .meldung(let t): return String(localized: String.LocalizationValue(t))
        }
    }
}

extension Gesamtzustand {
    /// Genau eine Handlungsempfehlung; nil = keine noetig.
    var empfehlungText: String? {
        switch empfehlung {
        case .keine: return nil
        case .schachtTauschen(let n): return schlagzeile == .plattenDefekt ? String(localized: "Festplatte in Schacht \(n) ersetzen (ausgefallen oder fehlt)") : String(localized: "Schacht \(n) durch eine größere Festplatte ersetzen")
        case .platteEinsetzen: return String(localized: "Festplatte einsetzen")
        case .platzSchaffen: return String(localized: "Dateien löschen oder eine größere Festplatte einsetzen")
        // Bedeutungen der blinkenden Lampen sind NICHT am Geraet belegt (drobo-utils/Betreiber): vorsichtig formuliert.
        case .abwarten: return String(localized: "Daten werden neu verteilt – Festplatte nicht entfernen, Drobo eingeschaltet lassen")
        case .zustandPruefen: return String(localized: "Achtung, Zustand der Festplatten prüfen")
        case .dateisystemPruefen: return String(localized: "Das Dateisystem prüfen (links „Ordner sichern“, dann „Jetzt prüfen“)")
        }
    }

    /// Satz zum Fuellstand, nur wo er die Schlagzeile erklaert.
    func platzText(gelb: Int, rot: Int) -> String? {
        guard let p = belegtProzent else { return nil }
        switch schlagzeile {
        case .platzKnapp: return String(localized: "Noch \(groesseText(frei)) frei, \(p) % sind belegt. Ab \(rot) % meldet die Drobo: Speicherplatz sehr knapp.")
        case .platzSehrKnapp: return String(localized: "Noch \(groesseText(frei)) frei, \(p) % sind belegt.")
        default: return nil
        }
    }

    var schutzText: String? {
        switch schutz {
        case .aktiv: return String(localized: "Schutz: aktiv, mindestens eine Festplatte darf ausfallen")
        case .keiner: return String(localized: "Schutz: keiner, ein Festplattenausfall würde Daten kosten")
        case .wirdHergestellt: return String(localized: "Schutz: wird wiederhergestellt")
        case nil: return nil
        }
    }

    var symbol: String { stufe == .kritisch ? "xmark.octagon.fill" : (stufe == .warnung ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") }
    var farbe: Color { stufe == .kritisch ? .red : (stufe == .warnung ? .orange : .green) }
    var stufeWort: String { stufe == .kritisch ? String(localized: "kritisch") : (stufe == .warnung ? String(localized: "Warnung") : String(localized: "in Ordnung")) }
}
