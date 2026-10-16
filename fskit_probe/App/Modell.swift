import AppKit
import DroboKern
import Foundation
import ServiceManagement
import UserNotifications

/// Ein Eintrag der Anzeige je Drobo: alles, was die Oberflaeche braucht, ohne dass sie den Kern selbst aufruft.
struct DroboAnsicht: Equatable {
    var eintrag: DroboEintrag
    var verbunden = false          // am Mac angeschlossen
    var eingehaengt = false
    var nurlesen = true
    var ort = ""
    var treiber = ""
    var freigabe: Modus?
    var gesamt: UInt64 = 0
    var belegt: UInt64 = 0
    var merker = Merker()
    var sicherungen: [String] = []

    var zustandText: String {
        if eintrag.rolle == .timemachine { return verbunden ? "Time-Machine-Ziel, angeschlossen" : "Time-Machine-Ziel, nicht angeschlossen" }
        if !verbunden { return "Nicht angeschlossen" }
        if !eingehaengt { return "Angeschlossen, nicht eingehängt" }
        return nurlesen ? "Eingehängt, nur lesen" : "Eingehängt, schreiben"
    }
    enum Stufe { case aus, bereit, lesen, schreiben, warnung }
    var stufe: Stufe {
        if merker.offenePruefung != nil { return .warnung }
        if !verbunden { return .aus }
        if !eingehaengt { return .bereit }
        return nurlesen ? .lesen : .schreiben
    }
}

struct Meldung: Identifiable { let id = UUID(); var titel: String; var text: String }

@MainActor
final class DroboModell: ObservableObject {
    let ablage = Datenablage()
    @Published var einstellungen: Einstellungen
    @Published var auswahl: String
    @Published var drobos: [String: DroboAnsicht] = [:]
    @Published var protokoll: [Datenablage.Eintrag] = []
    @Published var tempo: [TempoMessung] = []
    @Published var hilfsdienst = "unbekannt"
    @Published var festplattenzugriff = "nicht geprüft"
    @Published var modul = ModulStatus(installiert: false, freigeschaltet: false)
    @Published var arbeit: String?
    @Published var meldung: Meldung?
    @Published var wegsichernBericht = ""
    private var waechter: [AbziehWaechter] = []
    private var timer: Timer?
    private var vorher: [String: DroboAnsicht.Stufe] = [:]

    init() {
        let e = ablage.einstellungen()
        einstellungen = e
        auswahl = e.drobos.first?.uuid ?? vorgabeUUID
    }

    var aktuell: DroboAnsicht? { drobos[auswahl] }
    var liste: [DroboAnsicht] { einstellungen.drobos.compactMap { drobos[$0.uuid] } }

    func kern(_ uuid: String) -> Kern { var k = Kern(uuid: uuid); k.ablage = ablage; return k }

    // MARK: Start / Aktualisieren

    func starten() {
        aktualisieren()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.aktualisieren(freigabe: false) } }
        waechterNeu()
    }

    func waechterNeu() {
        waechter.forEach { $0.stop() }
        waechter = einstellungen.drobos.filter { $0.rolle == .arbeitsvolume }.map { d in
            let w = AbziehWaechter(uuid: d.uuid, ablage: ablage) { [weak self] ereignis in
                Task { @MainActor in
                    guard let self else { return }
                    if case .getrennt(_, let schreiben) = ereignis, schreiben { self.mitteilen("Drobo im Schreibzustand getrennt", "Vor dem nächsten Einhängen wird das Laufwerk geprüft. Beim nächsten Mal bitte zuerst aushaengen.") }
                    self.aktualisieren(freigabe: false)
                }
            }
            w.start(); return w
        }
    }

    func aktualisieren(freigabe: Bool = true) {
        let ds = einstellungen.drobos
        let alt = drobos
        Task.detached { [ablage] in
            var neu: [String: DroboAnsicht] = [:]
            for d in ds {
                var k = Kern(uuid: d.uuid); k.ablage = ablage
                var a = DroboAnsicht(eintrag: d)
                if let z = try? k.zustand(mitFreigabe: freigabe) {
                    switch z.verbindung {
                    case .nichtAngeschlossen: break
                    case .angeschlossen: a.verbunden = true
                    case .eingehaengt(_, let e):
                        a.verbunden = true; a.eingehaengt = true; a.nurlesen = e.nurlesen; a.ort = e.ort
                        switch e.treiber { case .hfsdrobo: a.treiber = "hfsdrobo"; case .kernel: a.treiber = "macOS"; case .andere(let s): a.treiber = s }
                        var s = statfs()
                        if statfs(e.ort, &s) == 0 { a.gesamt = UInt64(s.f_blocks) * UInt64(s.f_bsize); a.belegt = a.gesamt - UInt64(s.f_bfree) * UInt64(s.f_bsize) }
                    }
                    a.freigabe = freigabe ? z.freigabe : alt[d.uuid]?.freigabe
                } else { a.freigabe = alt[d.uuid]?.freigabe }
                a.merker = ablage.merker(d.uuid)
                a.sicherungen = eigeneSicherungen(ort: ablage.einstellungen().sicherungOrt, uuid: d.uuid).reversed()
                neu[d.uuid] = a
            }
            let m = modulStatus()
            let hd = Self.dienstText()
            await MainActor.run { [neu] in self.uebernehmen(neu, modul: m, dienst: hd) }
        }
    }

    nonisolated static func dienstText() -> String {
        switch SMAppService.daemon(plistName: "de.begod.drobohelper.plist").status {
        case .enabled: return "bereit"
        case .requiresApproval: return "wartet auf Freigabe"
        case .notRegistered: return "nicht eingerichtet"
        case .notFound: return "nicht gefunden"
        @unknown default: return "unbekannt"
        }
    }

    private func uebernehmen(_ neu: [String: DroboAnsicht], modul m: ModulStatus, dienst: String) {
        for (u, a) in neu {
            if let v = vorher[u], v != a.stufe {
                let n = a.eintrag.name
                switch (v, a.stufe) {
                case (.aus, .bereit): mitteilen("\(n) angeschlossen", "Zum Einhängen die App oeffnen.")
                case (_, .aus): mitteilen("\(n) getrennt", "")
                case (.bereit, .lesen): mitteilen("\(n) eingehängt", "Nur lesen.")
                case (.bereit, .schreiben): mitteilen("\(n) eingehängt", "Zum Schreiben. Metadaten-Sicherung liegt bereit.")
                case (_, .warnung): mitteilen("Warnung zu \(n)", a.merker.offenePruefung ?? "")
                default: break
                }
            }
            vorher[u] = a.stufe
        }
        drobos = neu; modul = m; hilfsdienst = dienst
        protokoll = ablage.protokollLesen()
        tempo = ablage.tempoVerlauf()
        if drobos[auswahl] == nil, let f = einstellungen.drobos.first { auswahl = f.uuid }
    }

    // MARK: Mitteilungen (Berechtigung erst beim ersten echten Ereignis)

    func mitteilen(_ titel: String, _ text: String) {
        guard einstellungen.mitteilungen else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let i = UNMutableNotificationContent(); i.title = titel; i.body = text
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: i, trigger: nil))
        }
    }

    // MARK: Aktionen (Kern blockiert -> im Hintergrund)

    func ausfuehren(_ was: String, _ arbeitsschritt: @escaping @Sendable () async throws -> String?) {
        guard arbeit == nil else { return }
        arbeit = was
        Task.detached {
            var fehler: String?; var info: String?
            do { info = try await arbeitsschritt() } catch { fehler = Self.fehlerText(error) }
            await MainActor.run {
                self.arbeit = nil
                if let f = fehler { self.meldung = Meldung(titel: was + " nicht möglich", text: f); self.ablage.protokoll("\(was): \(f)") }
                else if let i = info { self.meldung = Meldung(titel: was, text: i) }
                self.aktualisieren()
            }
        }
    }

    nonisolated static func fehlerText(_ e: Error) -> String {
        if let f = e as? Fehler { return f.description }
        if let f = e as? AppFehler { return f.description }
        return "\(e)"
    }

    func einhaengen(schreiben: Bool) {
        let u = auswahl, ort = einstellungen.einhaengeort
        let k = kern(u)
        ausfuehren(schreiben ? "Zum Schreiben einhängen" : "Einhängen") {
            if schreiben { try k.freigabeSetzen(.schreiben) } else if try k.listeLesen(u) == nil { try k.freigabeSetzen(.nurlesen) }
            _ = try k.einhaengen(modus: schreiben ? .schreiben : .nurlesen, ort: ort); return nil
        }
    }

    func aushaengen() {
        let k = kern(auswahl)
        ausfuehren("Aushängen") {
            if let p = try k.aushaengen(), !p.ok { return "Das Laufwerk ist ausgehängt. Die Prüfung nach dem Schreiben hat Auffälligkeiten gefunden: " + p.probleme.joined(separator: "; ") }
            return nil
        }
    }

    func neuZumSchreiben() {
        let u = auswahl, ort = einstellungen.einhaengeort; let k = kern(u)
        ausfuehren("Zum Schreiben neu einhängen") {
            try k.aushaengen()
            try k.freigabeSetzen(.schreiben)
            _ = try k.einhaengen(modus: .schreiben, ort: ort); return nil
        }
    }

    func tempoTesten(schreiben: Bool) {
        let k = kern(auswahl)
        ausfuehren(schreiben ? "Schreibtempo messen" : "Lesetempo messen") {
            let r = try k.tempoTesten(schreiben: schreiben)
            return String(format: "%.0f MB/s", r.mbProSekunde)
        }
    }

    func pruefen() {
        let k = kern(auswahl); let u = auswahl
        ausfuehren("Prüfung") {
            guard let m = finden(uuid: u) else { throw Fehler.nichtGefunden(u) }
            if einhaengungen()[m.geraet] != nil { throw Fehler.eingehaengt(m.geraet) }
            _ = k.helfer("freigeben", u); defer { _ = k.helfer("zurueckgeben", u) }
            let r = try nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse)
            k.ablage.merkerAendern(u) { $0.letztePruefung = r; if r.ok { $0.offenePruefung = nil } }
            return r.ok ? "In Ordnung." : "Auffälligkeiten: " + r.probleme.joined(separator: "; ")
        }
    }

    func zugriffPruefen() {
        let k = kern(auswahl); let u = auswahl
        ausfuehren("Festplattenzugriff prüfen") {
            guard finden(uuid: u) != nil else { throw Fehler.nichtGefunden(u) }
            let a = k.helfer("freigeben", u); let b = k.helfer("zurueckgeben", u)
            let ok = a == nil && b == nil
            await MainActor.run { self.festplattenzugriff = ok ? "in Ordnung" : "fehlt" }
            return ok ? "Der Hilfsdienst darf auf das Laufwerk zugreifen." : "Der Hilfsdienst darf nicht auf das Laufwerk zugreifen: \(a ?? b ?? ""). In den Systemeinstellungen unter Datenschutz und Sicherheit, Festplattenvollzugriff, den Drobo-Hilfsdienst einschalten."
        }
    }

    func wegsichern(quelle: String, ziel: String) {
        let k = kern(auswahl)
        wegsichernBericht = "Läuft ..."
        ausfuehren("Ordner wegsichern") {
            let b = try k.wegsichern(quelle: quelle, ziel: ziel)
            await MainActor.run { self.wegsichernBericht = (b.ok ? "Fertig: " : "Mit Fehlern: ") + b.text }
            return nil
        }
    }

    func einstellungenSpeichern() { ablage.einstellungenSetzen(einstellungen); waechterNeu(); aktualisieren() }

    func imFinderOeffnen() { if let a = aktuell, a.eingehaengt { NSWorkspace.shared.open(URL(fileURLWithPath: a.ort)) } }

    func dienstRegistrieren() {
        do { try SMAppService.daemon(plistName: "de.begod.drobohelper.plist").register() } catch { meldung = Meldung(titel: "Hilfsdienst", text: "\(error)") }
        if Self.dienstText() == "wartet auf Freigabe" { SMAppService.openSystemSettingsLoginItems() }
        aktualisieren()
    }

    var spotlightHinweisNoetig: Bool {
        guard let a = aktuell, a.eintrag.rolle == .arbeitsvolume, !einstellungen.spotlightAusgeschlossen else { return false }
        return (a.eingehaengt && !a.nurlesen) || (!a.eingehaengt && einstellungen.vorgabeSchreiben)
    }
}
