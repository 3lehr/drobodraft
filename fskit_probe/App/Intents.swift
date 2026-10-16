import AppIntents
import DroboKern

/// Kurzbefehle: laufen im App-Prozess und rufen nur den Kern. Erste Drobo vom Typ Arbeitsvolume (Auswahl folgt, sobald mehrere Arbeitsvolumes vorkommen).
enum KurzbefehlFehler: Error, CustomLocalizedStringResourceConvertible {
    case fehler(String)
    var localizedStringResource: LocalizedStringResource { switch self { case .fehler(let s): return "\(s)" } }
}

func kurzKern() throws -> Kern {
    let a = Datenablage()
    guard let d = a.einstellungen().drobos.first(where: { $0.rolle == .arbeitsvolume }) else { throw KurzbefehlFehler.fehler("Keine Drobo als Arbeitsvolume eingetragen.") }
    var k = Kern(uuid: d.uuid); k.ablage = a; return k
}

func kurz<T>(_ f: () throws -> T) throws -> T {
    do { return try f() } catch let e as Fehler { throw KurzbefehlFehler.fehler(e.description) } catch let e as AppFehler { throw KurzbefehlFehler.fehler(e.description) }
}

enum EinhaengeArt: String, AppEnum {
    case nurLesen, schreiben
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Einhängeart"
    static var caseDisplayRepresentations: [EinhaengeArt: DisplayRepresentation] = [.nurLesen: "Nur lesen", .schreiben: "Schreiben"]
}

struct DroboEinhaengenIntent: AppIntent {
    static var title: LocalizedStringResource = "Drobo einhängen"
    static var description = IntentDescription("Hängt die Drobo nur lesend oder zum Schreiben ein. Zum Schreiben wird vorher die Verwaltungsdaten-Sicherung angelegt.")
    @Parameter(title: "Art", default: .nurLesen) var art: EinhaengeArt
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let k = try kurzKern(); let ort = k.ablage.einstellungen().einhaengeort; let sch = art == .schreiben
        try kurz {
            if sch { try k.freigabeSetzen(.schreiben) } else if try k.listeLesen(k.uuid) == nil { try k.freigabeSetzen(.nurlesen) }
            _ = try k.einhaengen(modus: sch ? .schreiben : .nurlesen, ort: ort)
        }
        return .result(dialog: "Drobo eingehängt (\(sch ? "Schreiben" : "nur lesen")).")
    }
}

struct DroboAushaengenIntent: AppIntent {
    static var title: LocalizedStringResource = "Drobo aushängen"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let k = try kurzKern()
        let p = try kurz { try k.aushaengen() }
        return .result(dialog: p == nil || p?.ok == true ? "Drobo ausgehängt." : "Drobo ausgehängt, aber die Prüfung hat Auffälligkeiten gefunden. Details im Protokoll.")
    }
}

struct DroboStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Drobo-Status"
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let k = try kurzKern(); let z = try kurz { try k.zustand(mitFreigabe: false) }
        return .result(value: z.kurz, dialog: "\(z.kurz)")
    }
}

struct DroboTempoIntent: AppIntent {
    static var title: LocalizedStringResource = "Drobo-Lesetempo messen"
    static var description = IntentDescription("Misst die Lesegeschwindigkeit an der eingehängten Drobo. Nur lesend.")
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let k = try kurzKern(); let r = try kurz { try k.tempoTesten() }
        return .result(value: r.mbProSekunde, dialog: "\(Int(r.mbProSekunde)) MB pro Sekunde.")
    }
}

struct DroboKurzbefehle: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DroboEinhaengenIntent(), phrases: ["Hänge \(.applicationName) ein"], shortTitle: "Einhängen", systemImageName: "externaldrive.badge.plus")
        AppShortcut(intent: DroboAushaengenIntent(), phrases: ["Hänge \(.applicationName) aus"], shortTitle: "Aushängen", systemImageName: "eject")
        AppShortcut(intent: DroboStatusIntent(), phrases: ["Status von \(.applicationName)"], shortTitle: "Status", systemImageName: "info.circle")
        AppShortcut(intent: DroboTempoIntent(), phrases: ["Tempo von \(.applicationName) messen"], shortTitle: "Tempotest", systemImageName: "speedometer")
    }
}
