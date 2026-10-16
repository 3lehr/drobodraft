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
    var belegungVH: Belegung?      // aus dem Volume-Header, auch ohne Einhaengung

    var zustandText: String {
        if eintrag.rolle == .timemachine { return verbunden ? String(localized: "Time-Machine-Ziel, angeschlossen") : String(localized: "Time-Machine-Ziel, nicht angeschlossen") }
        if !verbunden { return String(localized: "Nicht angeschlossen") }
        if !eingehaengt { return String(localized: "Angeschlossen, nicht eingehängt") }
        return nurlesen ? String(localized: "Eingehängt, nur lesen") : String(localized: "Eingehängt, schreiben")
    }
    enum Stufe { case aus, bereit, lesen, schreiben, warnung }
    var stufe: Stufe {
        if merker.offenePruefung != nil { return .warnung }
        if !verbunden { return .aus }
        if !eingehaengt { return .bereit }
        return nurlesen ? .lesen : .schreiben
    }
}

/// ISO-Zeit aus Protokoll/Merker lesbar und in der Systemsprache.
func zeitLesbar(_ iso: String) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: iso) else { return iso }
    return d.formatted(date: .abbreviated, time: .shortened)
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
    @Published var restoreAuswahl = ""
    @Published var restoreProbeText = ""
    @Published var restoreProbeFuer = ""      // Name der Sicherung, fuer die der Probelauf lief
    @Published var anmeldeStart = false
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
        anmeldeStart = SMAppService.mainApp.status == .enabled
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
                    if case .getrennt(_, let schreiben) = ereignis, schreiben { self.mitteilen(String(localized: "Drobo im Schreibzustand getrennt"), String(localized: "Vor dem nächsten Einhängen wird das Laufwerk geprüft. Beim nächsten Mal bitte zuerst aushängen.")) }
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
            var zugriff: Bool?
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
                if freigabe, a.verbunden, !a.eingehaengt, d.rolle == .arbeitsvolume {
                    // wirkungslose Dienst-Probe + Belegung aus dem Header (nur wenn noch unbekannt oder aelter als 10 min)
                    zugriff = k.zugriffPruefen() == nil
                    let mk = ablage.merker(d.uuid)
                    let alt = mk.belegung.flatMap { b in ISO8601DateFormatter().date(from: b.zeit) }.map { Date().timeIntervalSince($0) > 600 } ?? true
                    if zugriff == true, alt { _ = try? k.belegungLesen() }
                }
                a.merker = ablage.merker(d.uuid)
                a.belegungVH = a.merker.belegung
                a.sicherungen = eigeneSicherungen(ort: ablage.einstellungen().sicherungOrt, uuid: d.uuid).reversed()
                neu[d.uuid] = a
            }
            let m = modulStatus()
            let hd = Self.dienstText()
            await MainActor.run { [neu, zugriff] in
                if let z = zugriff { self.festplattenzugriff = z ? String(localized: "in Ordnung") : String(localized: "fehlt") }
                self.uebernehmen(neu, modul: m, dienst: hd)
            }
        }
    }

    nonisolated static func dienstText() -> String {
        switch SMAppService.daemon(plistName: helferPlistName).status {
        case .enabled: return String(localized: "bereit")
        case .requiresApproval: return String(localized: "wartet auf Freigabe")
        case .notRegistered: return String(localized: "nicht eingerichtet")
        case .notFound: return String(localized: "nicht gefunden")
        @unknown default: return String(localized: "unbekannt")
        }
    }

    private func uebernehmen(_ neu: [String: DroboAnsicht], modul m: ModulStatus, dienst: String) {
        for (u, a) in neu {
            if let v = vorher[u], v != a.stufe {
                let n = a.eintrag.name
                switch (v, a.stufe) {
                case (.aus, .bereit): mitteilen(String(localized: "\(n) angeschlossen"), String(localized: "Zum Einhängen die App öffnen."))
                case (_, .aus): mitteilen(String(localized: "\(n) getrennt"), "")
                case (.bereit, .lesen): mitteilen(String(localized: "\(n) eingehängt"), String(localized: "Nur lesen."))
                case (.bereit, .schreiben): mitteilen(String(localized: "\(n) eingehängt"), String(localized: "Zum Schreiben. Metadaten-Sicherung liegt bereit."))
                case (_, .warnung): mitteilen(String(localized: "Warnung zu \(n)"), a.merker.offenePruefung ?? "")
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
            if let p = try k.aushaengen(), !p.ok { return String(localized: "Das Laufwerk ist ausgehängt. Die Prüfung nach dem Schreiben hat Auffälligkeiten gefunden: ") + p.probleme.joined(separator: "; ") }
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

    /// Wirkungslose Probe im Dienst (chown auf den bisherigen Eigentümer); Ergebnis in der Statuszeile.
    func zugriffPruefen() {
        let k = kern(auswahl); let u = auswahl
        ausfuehren("Festplattenzugriff prüfen") {
            guard finden(uuid: u) != nil else { throw Fehler.nichtGefunden(u) }
            let f = k.zugriffPruefen()
            await MainActor.run { self.festplattenzugriff = f == nil ? String(localized: "in Ordnung") : String(localized: "fehlt") }
            return f == nil ? String(localized: "Der Hilfsdienst darf auf das Laufwerk zugreifen.") : String(localized: "Der Hilfsdienst darf nicht auf das Laufwerk zugreifen. Bitte unter Systemeinstellungen, Datenschutz & Sicherheit, Festplattenvollzugriff den Drobo-Hilfsdienst einschalten.") + " (\(f ?? ""))"
        }
    }

    func festplattenzugriffOeffnen() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }

    // MARK: Sicherung zurückspielen (Probelauf, dann ausdrückliche Bestätigung)

    func restoreProbe() {
        let k = kern(auswahl); let name = restoreAuswahl
        restoreProbeText = ""; restoreProbeFuer = ""
        ausfuehren("Probelauf") {
            let p = try k.zurueckspielenProbe(sicherung: name)
            await MainActor.run { self.restoreProbeText = p.text; self.restoreProbeFuer = name }
            return nil
        }
    }

    func restoreAusfuehren() {
        let k = kern(auswahl); let name = restoreAuswahl
        ausfuehren("Zurückspielen") {
            let r = try k.zurueckspielen(sicherung: name)
            await MainActor.run { self.restoreProbeText = ""; self.restoreProbeFuer = "" }
            return r.ok ? String(localized: "Zurückgespielt. Prüfung danach: in Ordnung.") : String(localized: "Zurückgespielt, aber die Prüfung danach hat Auffälligkeiten gefunden: ") + r.probleme.joined(separator: "; ")
        }
    }

    func anmeldeStartSetzen(_ an: Bool) {
        do { if an { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { meldung = Meldung(titel: "Beim Anmelden starten", text: "\(error.localizedDescription)") }
        anmeldeStart = SMAppService.mainApp.status == .enabled
    }

    func wegsichern(quelle: String, ziel: String) {
        let k = kern(auswahl)
        wegsichernBericht = String(localized: "Läuft ...")
        ausfuehren("Ordner wegsichern") {
            let b = try k.wegsichern(quelle: quelle, ziel: ziel)
            await MainActor.run { self.wegsichernBericht = (b.ok ? String(localized: "Fertig: ") : String(localized: "Mit Fehlern: ")) + b.text }
            return nil
        }
    }

    /// Ordnerwahl für die Metadaten-Sicherung (kein fester Pfad vorgegeben).
    func sicherungsOrtWaehlen() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = String(localized: "Wählen"); p.message = String(localized: "Sicherungsort: nicht das Startvolume und nicht die Drobo")
        if p.runModal() == .OK, let u = p.url { einstellungen.sicherungOrt = u.path; einstellungenSpeichern() }
    }

    func einstellungenSpeichern() { ablage.einstellungenSetzen(einstellungen); waechterNeu(); aktualisieren() }

    func imFinderOeffnen() { if let a = aktuell, a.eingehaengt { NSWorkspace.shared.open(URL(fileURLWithPath: a.ort)) } }

    func dienstRegistrieren() {
        do { try SMAppService.daemon(plistName: helferPlistName).register() } catch { meldung = Meldung(titel: "Hilfsdienst", text: "\(error)") }
        if SMAppService.daemon(plistName: helferPlistName).status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        aktualisieren()
    }

    var spotlightHinweisNoetig: Bool {
        guard let a = aktuell, a.eintrag.rolle == .arbeitsvolume, !einstellungen.spotlightAusgeschlossen else { return false }
        return (a.eingehaengt && !a.nurlesen) || (!a.eingehaengt && einstellungen.vorgabeSchreiben)
    }
}
