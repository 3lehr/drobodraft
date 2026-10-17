#if DEBUG
import DroboKern
import Foundation

/// Nur Debug-Bau, nur mit Umgebung DROBO_DEMO=5c|pro|beide (und eigenem DROBO_DATEN-Ordner): Testdaten fuer Bildschirmfotos und die Pruefung ohne Geraet.
/// Werte: Drobo 5C vom 2026-10-16 (Status 0x28004, 4,25 von 67,79 TB frei, Schacht 1 gelb) und DroboPro (0x28000, 0,99 von 17,88 TB belegt).
/// Temperatur/Restleben/Fehler der Platten sind ERFUNDEN (die echte 5C lieferte keine), damit die Einzelheiten sichtbar werden.
enum DemoDaten {
    static var art: String? { ProcessInfo.processInfo.environment["DROBO_DEMO"].flatMap { $0.isEmpty ? nil : $0 } }
    /// DROBO_DEMO_SEITE=uebersicht|laufwerke|protokoll|tempo|volume|finden (Startansicht), DROBO_DEMO_SCHACHT=n (Einzelheiten dieses Schachts offen).
    static var seite: Abschnitt? { ProcessInfo.processInfo.environment["DROBO_DEMO_SEITE"].flatMap { s in Abschnitt.allCases.first { "\($0)" == s } } }
    /// DROBO_DEMO_PROBLEM=1: Treibermodul "nicht freigeschaltet" (zeigt die Statusleiste).
    static var problem: Bool { ProcessInfo.processInfo.environment["DROBO_DEMO_PROBLEM"] != nil }
    static var schacht: Int? { ProcessInfo.processInfo.environment["DROBO_DEMO_SCHACHT"].flatMap { Int($0) } }
    /// DROBO_DEMO_LAMPEN=1: DroboPro mit allen Lampencodes (gruen, gelb, rot, rot/gruen, rot/gelb, rot/aus, leer, unbekannt 0x42).
    static var lampen: Bool { ProcessInfo.processInfo.environment["DROBO_DEMO_LAMPEN"] != nil }
    static let uuid5C = "00000000-0000-4000-8000-0000000005C0", uuidPro = "00000000-0000-4000-8000-00000000D0B0"

    static func eintraege() -> [DroboEintrag]? {
        guard let a = art else { return nil }
        let c = DroboEintrag(uuid: uuid5C, name: "Drobo 5C"), p = DroboEintrag(uuid: uuidPro, name: "DroboPro", netz: NetzZiel(host: "192.0.2.10", lun: 0, iqn: nil, luns: [NetzLunEintrag(lun: 0, uuid: "00000000-0000-4000-8000-00000000D0B1", name: "ARCHIV"), NetzLunEintrag(lun: 1, uuid: uuidPro, name: "DROPRO1")]))
        return a == "5c" ? [c] : (a == "pro" ? [p] : [c, p])
    }

    static func schacht(_ nr: Int, _ f: SchachtFarbe, _ kap: UInt64, _ modell: String, temp: Int? = nil, leben: Int? = nil) -> Schacht {
        Schacht(nr: nr, farbe: f, fehler: 0, modell: modell, kapazitaet: kap, temperatur: temp, restleben: leben)
    }

    static func status(modell: String, bits: UInt32, schaechte: [Schacht], frei: UInt64, benutzt: UInt64, geschuetzt: UInt64, roh: UInt64) -> DroboStatus {
        var s = DroboStatus(zeit: Date(), ok: true, fehler: "", modell: modell, firmware: "Apr 16 2021, 00:19:56", firmwareBuild: 50532, protokoll: "0.11", schaechte: schaechte,
                            kapazitaet: DroboKapazitaet(frei: frei, benutzt: benutzt, gesamtGeschuetzt: geschuetzt, gesamtUngeschuetzt: roh), statusBits: bits, relayout: 0, meldungen: [], schwere: .ok, unbelegt: [:])
        s.meldungen = bits & 0x4 != 0 ? [DroboKern.Meldung(bit: 0x4, text: "Speicherplatz wird knapp (gelbe Schwelle erreicht)", schwere: .warnung)] : []
        s.schwere = [s.meldungen.map(\.schwere).max() ?? .ok, schaechte.contains { $0.farbe == .gelb } ? Schweregrad.warnung : .ok].max()!
        return s
    }

    static func ansichten() -> [String: DroboAnsicht]? {
        guard let es = eintraege() else { return nil }
        var r: [String: DroboAnsicht] = [:]
        for e in es {
            var a = DroboAnsicht(eintrag: e)
            a.verbunden = true
            var m = Merker(); var p = PruefErgebnis(); p.ok = true; p.zeit = "2026-10-16T18:20:00Z"; m.letztePruefung = p; a.merker = m
            if e.netz == nil {
                a.hw = status(modell: "5C Gen3", bits: 0x28004, schaechte: [
                    schacht(1, .gelb, 16_000_900_661_248, "ST16000NM001G-2K"), schacht(2, .gruen, 18_000_207_937_536, "ST18000NM000J-2T", temp: 34, leben: nil),
                    schacht(3, .gruen, 18_000_207_937_536, "ST18000NM000J-2T"), schacht(4, .gruen, 18_000_207_937_536, "ST18000NM000J-2T"), schacht(5, .gruen, 18_000_207_937_536, "ST18000NM000J-2T")],
                    frei: 4_250_000_000_000, benutzt: 63_540_000_000_000, geschuetzt: 67_790_000_000_000, roh: 70_000_000_000_000)
            } else {
                a.hw = status(modell: "Pro", bits: 0x28000, schaechte: [
                    schacht(1, .gruen, 8_001_563_222_016, "ST8000DM004-2CX188"), schacht(2, .gruen, 3_000_592_982_016, "ST3000DM001-1CH166"), schacht(3, .gruen, 3_000_592_982_016, "ST3000DM001-1CH166"),
                    schacht(4, .gruen, 3_000_592_982_016, "ST3000DM001-1CH166"), schacht(5, .gruen, 3_000_592_982_016, "ST3000DM001-1CH166"),
                    schacht(6, .leer, 0, ""), schacht(7, .leer, 0, ""), schacht(8, .leer, 0, "")],
                    frei: 16_890_000_000_000, benutzt: 990_000_000_000, geschuetzt: 17_880_000_000_000, roh: 20_000_000_000_000)
                if lampen, var h = a.hw {
                    let f: [SchachtFarbe] = [.gruen, .gelb, .rot, .rotGruen, .rotGelb, .rotAus, .leer, .unbekannt(0x42)]
                    for i in h.schaechte.indices { h.schaechte[i].farbe = f[i] }
                    h.schwere = .kritisch; a.hw = h
                }
                a.luns = [LunEintrag(lun: 0, groesse: 16 << 40, schema: "GPT", partitionBytes: 2 << 40, uuid: "00000000-0000-4000-8000-00000000D0B1"), LunEintrag(lun: 1, groesse: 16 << 40, schema: "GPT", partitionBytes: 2 << 40, uuid: uuidPro), LunEintrag(lun: 2, groesse: 16 << 40, schema: "-", partitionBytes: nil, uuid: nil)]
                a.lunEingehaengt = [1: true]
                a.netz = NetzInfo(name: "DroboPro", gelbProzent: 85, rotProzent: 95); a.netzStand = Date()
            }
            r[e.uuid] = a
        }
        return r
    }
}
#endif
