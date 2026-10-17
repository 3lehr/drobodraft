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
    var hw: DroboStatus?           // Status der Drobo selbst (Dext), nil = kein Treiber/keine Daten
    var netz: NetzInfo?            // Netzwerk-Drobo: Name und Schwellen aus den Statusseiten
    var netzStand: Date?           // Netzwerk-Drobo: wann der Status zuletzt gelesen wurde
    var netzFehler: String?        // Netzwerk-Drobo: warum der Status nicht gelesen werden konnte

    var zustandText: String {
        if eintrag.netz != nil {
            if !verbunden { return String(localized: "Nicht erreichbar") }
            if !eingehaengt { return String(localized: "Verbunden, nicht eingehängt") }
            return nurlesen ? String(localized: "Eingehängt, nur lesen") : String(localized: "Eingehängt, schreiben")
        }
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

/// Abbruchzeichen zwischen Oberfläche und Messfaden.
final class StoppZeichen: @unchecked Sendable {
    private let sperre = NSLock(); private var wert = false
    var gesetzt: Bool { sperre.lock(); defer { sperre.unlock() }; return wert }
    func setzen() { sperre.lock(); wert = true; sperre.unlock() }
    func zuruecksetzen() { sperre.lock(); wert = false; sperre.unlock() }
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
    @Published var hilfsdienst = String(localized: "unbekannt")
    @Published var festplattenzugriff = String(localized: "nicht geprüft")
    @Published var modul = ModulStatus(installiert: false, freigeschaltet: false)
    @Published var arbeit: String?
    @Published var meldung: Meldung?
    @Published var tempoUUID = ""
    @Published var tempoGB = 1
    @Published var tempoLaeuft = false
    @Published var tempoPhase = ""              // "" | schreiben | lesen
    @Published var tempoAnteil = 0.0
    @Published var tempoZyklen = 0
    @Published var tempoFehler: String?
    @Published var tempoSchreibenLive: Double?
    @Published var tempoLesenLive: Double?
    @Published var tempoSpitze = 0.0
    let tempoStopp = StoppZeichen()
    @Published var wegsichernBericht = ""
    @Published var restoreAuswahl = ""
    @Published var restoreProbeText = ""
    @Published var restoreProbeFuer = ""      // Name der Sicherung, fuer die der Probelauf lief
    @Published var anmeldeStart = false
    /// Angeschlossene Drobos (SCSI-Hersteller "Drobo"), die noch nicht eingerichtet sind.
    @Published var erkannte: [ErkannteDrobo] = []
    private var waechter: [AbziehWaechter] = []
    /// Netzwerk-Drobos: letzter Leseversuch je UUID (die DroboPro bedient nur eine Verbindung; nicht dauernd anklopfen, nicht waehrend sie eingehaengt ist).
    private var netzVersuch: [String: Date] = [:]
    @Published var netzTreffer: [NetzLun] = []
    @Published var netzSucheLaeuft = false
    /// "Drobos suchen": im LAN gefundene, noch nicht eingerichtete Drobos (USB-Funde stehen in `erkannte`).
    @Published var lanErkannte: [LanDrobo] = []
    @Published var sucheLaeuft = false
    @Published var sucheInfo: String?
    @Published var netzSucheFehler: String?
    private var timer: Timer?
    private var vorher: [String: DroboAnsicht.Stufe] = [:]
    private var vorherSchwere: [String: Schweregrad] = [:]

    init() {
        let e = ablage.einstellungen()
        einstellungen = e
        auswahl = e.drobos.first?.uuid ?? ""
    }

    var aktuell: DroboAnsicht? { drobos[auswahl] }
    /// Schlimmster Zustand aller Drobos fuer die Menueleiste (nil = keine Statusdaten).
    var gesamtSchwere: Schweregrad? { drobos.values.compactMap { $0.hw?.schwere }.max() }
    var liste: [DroboAnsicht] { einstellungen.drobos.compactMap { drobos[$0.uuid] } }

    func kern(_ uuid: String) -> Kern { var k = Kern(uuid: uuid); k.ablage = ablage; return k }

    // MARK: Start / Aktualisieren

    func starten() {
        anmeldeStart = SMAppService.mainApp.status == .enabled
        aktualisieren()
        drobosSuchen()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.aktualisieren(freigabe: false) } }
        waechterNeu()
    }

    func waechterNeu() {
        waechter.forEach { $0.stop() }
        waechter = einstellungen.drobos.filter { $0.rolle == .arbeitsvolume && $0.netz == nil }.map { d in
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
        let jetzt = Date()
        let netzLesen = Set(ds.filter { d in d.netz != nil && (freigabe || jetzt.timeIntervalSince(netzVersuch[d.uuid] ?? .distantPast) > 60) }.map { $0.uuid })
        for u in netzLesen { netzVersuch[u] = jetzt }
        Task.detached { [ablage] in
            var neu: [String: DroboAnsicht] = [:]
            var zugriff: Bool?
            for d in ds {
                var k = Kern(uuid: d.uuid); k.ablage = ablage
                var a = DroboAnsicht(eintrag: d)
                if let nz = d.netz {            // Netzwerk-Drobo: eigener Weg, kein Geraeteknoten
                    let v = alt[d.uuid]
                    (a.hw, a.netz, a.netzStand, a.netzFehler) = (v?.hw, v?.netz, v?.netzStand, v?.netzFehler)
                    if let e = netzEinhaengung(lun: nz.lun) {      // eingehaengt: keine zweite Sitzung oeffnen
                        a.verbunden = true; a.eingehaengt = true; a.nurlesen = e.nurlesen; a.ort = e.ort; a.treiber = "iSCSI"
                        var s = statfs()
                        if statfs(e.ort, &s) == 0 { a.gesamt = UInt64(s.f_blocks) * UInt64(s.f_bsize); a.belegt = a.gesamt - UInt64(s.f_bfree) * UInt64(s.f_bsize) }
                    } else if netzLesen.contains(d.uuid) {
                        do { let (st, info) = try netzStatusLesen(host: nz.host); (a.hw, a.netz, a.netzStand, a.netzFehler) = (st, info, Date(), nil) }
                        catch { (a.hw, a.netzFehler) = (nil, Self.fehlerText(error)) }
                    }
                    a.verbunden = a.verbunden || (a.hw != nil && a.netzFehler == nil)
                    a.merker = ablage.merker(d.uuid)
                    a.sicherungen = eigeneSicherungen(ort: ablage.einstellungen().sicherungOrt, uuid: d.uuid).reversed()
                    neu[d.uuid] = a
                    continue
                }
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
                if a.verbunden { a.hw = liesDroboStatus(uuid: d.uuid) }
                a.sicherungen = eigeneSicherungen(ort: ablage.einstellungen().sicherungOrt, uuid: d.uuid).reversed()
                neu[d.uuid] = a
            }
            let bekannt = Set(ds.map { $0.uuid })
            let erk = erkenneDrobos().filter { !bekannt.contains($0.uuid) }
            let m = modulStatus()
            let hd = Self.dienstText()
            await MainActor.run { [neu, zugriff] in
                if let z = zugriff { self.festplattenzugriff = z ? String(localized: "in Ordnung") : String(localized: "fehlt") }
                self.erkannte = erk
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
            if let s = a.hw?.schwere {
                if let v = vorherSchwere[u], s > v {
                    let n = a.eintrag.name
                    mitteilen(s == .kritisch ? String(localized: "\(n): kritischer Zustand") : String(localized: "\(n): Warnung"), a.hw?.meldungen.first { $0.schwere == s }.map { String(localized: String.LocalizationValue($0.text)) } ?? "")
                }
                vorherSchwere[u] = s
            }
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

    /// Netzwerk-Drobo einhaengen (ueber den Hilfsdienst); Schreiben nur mit Metadaten-Sicherung (der Kern lehnt sonst ab).
    func netzEinhaengen(_ nz: NetzZiel, schreiben: Bool) {
        let e = einstellungen
        ausfuehren(schreiben ? "Zum Schreiben einhängen" : "Einhängen") { [ablage] in
            try iscsiEinhaengen(host: nz.host, lun: nz.lun, schreiben: schreiben, ziel: nil, ort: nil, sicherung: schreiben ? (e.sicherungOrt, e.sicherungAnzahl) : nil,
                                meldung: { ablage.protokoll("Netzwerk-Drobo: \($0)") })
            return nil
        }
    }

    func einhaengen(schreiben: Bool) {
        if let nz = aktuell?.eintrag.netz { return netzEinhaengen(nz, schreiben: schreiben) }
        let u = auswahl, ort = einstellungen.einhaengeort
        let k = kern(u)
        ausfuehren(schreiben ? "Zum Schreiben einhängen" : "Einhängen") {
            if schreiben { try k.freigabeSetzen(.schreiben) } else if try k.listeLesen(u) == nil { try k.freigabeSetzen(.nurlesen) }
            _ = try k.einhaengen(modus: schreiben ? .schreiben : .nurlesen, ort: ort); return nil
        }
    }

    func aushaengen() {
        if let nz = aktuell?.eintrag.netz {
            ausfuehren("Aushängen") { [ablage] in try iscsiAushaengen(ort: iscsiOrt(nz.lun)); ablage.protokoll("Netzwerk-Drobo ausgehängt"); return nil }
            return
        }
        let k = kern(auswahl)
        ausfuehren("Aushängen") {
            if let p = try k.aushaengen(), !p.ok { return String(localized: "Das Laufwerk ist ausgehängt. Die Prüfung nach dem Schreiben hat Auffälligkeiten gefunden: ") + p.probleme.joined(separator: "; ") }
            return nil
        }
    }

    func neuZumSchreiben() {
        if let nz = aktuell?.eintrag.netz {
            let e = einstellungen
            ausfuehren("Zum Schreiben neu einhängen") { [ablage] in
                try iscsiAushaengen(ort: iscsiOrt(nz.lun))
                try iscsiEinhaengen(host: nz.host, lun: nz.lun, schreiben: true, ziel: nil, ort: nil, sicherung: (e.sicherungOrt, e.sicherungAnzahl), meldung: { ablage.protokoll("Netzwerk-Drobo: \($0)") })
                return nil
            }
            return
        }
        let u = auswahl, ort = einstellungen.einhaengeort; let k = kern(u)
        ausfuehren("Zum Schreiben neu einhängen") {
            try k.aushaengen()
            try k.freigabeSetzen(.schreiben)
            _ = try k.einhaengen(modus: .schreiben, ort: ort); return nil
        }
    }

    // MARK: Tempo (Zyklen bis Stopp)

    /// Laufwerk der Tempo-Ansicht: gewählte, sonst die in der Seitenleiste gewählte Drobo.
    var tempoZiel: DroboAnsicht? { drobos[tempoUUID] ?? aktuell }
    var tempoStartbar: Bool { arbeit == nil && tempoZiel.map { $0.eingehaengt && $0.eintrag.rolle == .arbeitsvolume && $0.eintrag.netz == nil } == true }
    func tempoZielWaehlen() { if drobos[tempoUUID] == nil || tempoUUID.isEmpty { tempoUUID = auswahl } }

    func tempoStoppen() { tempoStopp.setzen() }

    func tempoStarten() {
        guard tempoStartbar, let z = tempoZiel else { return }
        let k = kern(z.eintrag.uuid); let schreiben = !z.nurlesen
        let groesse = UInt64(tempoGB) * 1_000_000_000; let stopp = tempoStopp
        stopp.zuruecksetzen()
        tempoFehler = nil; tempoLaeuft = true; tempoZyklen = 0; tempoPhase = ""; tempoAnteil = 0
        tempoSchreibenLive = nil; tempoLesenLive = nil; tempoSpitze = 0; arbeit = "Tempotest"
        Task.detached {
            var fehler: String?
            do {
                try k.tempoLauf(schreiben: schreiben, groesse: groesse, zyklen: nil, fortschritt: { f in
                    Task { @MainActor in self.tempoFortschritt(f) }
                }, zyklus: { z in
                    Task { @MainActor in
                        self.tempoZyklen += 1
                        if let w = z.schreiben { self.tempoSchreibenLive = w.mbProSekunde }
                        if let r = z.lesen { self.tempoLesenLive = r.mbProSekunde }
                        self.tempo = self.ablage.tempoVerlauf()
                    }
                }, abbrechen: { stopp.gesetzt })
            } catch { fehler = Self.fehlerText(error) }
            await MainActor.run {
                self.tempoLaeuft = false; self.tempoPhase = ""; self.arbeit = nil; self.tempoFehler = fehler
                if let f = fehler { self.ablage.protokoll("Tempotest: \(f)") }
                self.tempo = self.ablage.tempoVerlauf(); self.aktualisieren()
            }
        }
    }

    private func tempoFortschritt(_ f: TempoFortschritt) {
        guard tempoLaeuft else { return }
        tempoPhase = f.art; tempoAnteil = f.von > 0 ? Double(f.bytes) / Double(f.von) : 0
        if f.art == "schreiben" { tempoSchreibenLive = f.mbProSekunde } else { tempoLesenLive = f.mbProSekunde }
        tempoSpitze = max(tempoSpitze, f.mbProSekunde, tempo.filter { $0.uuid == tempoUUID }.map { $0.mbProSekunde }.max() ?? 0)
    }

    /// Skala der Rundinstrumente: nächste "runde" Zahl über der Spitze, wächst nur.
    var tempoSkala: Double {
        let h = max(tempoSpitze, tempoSchreibenLive ?? 0, tempoLesenLive ?? 0, tempo.filter { $0.uuid == tempoZiel?.eintrag.uuid }.map { $0.mbProSekunde }.max() ?? 0)
        return [100.0, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000, 5000].first { $0 >= h } ?? (h * 1.1).rounded(.up)
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

    /// Erkannte Drobo einrichten (Rolle Arbeitsvolume; Time-Machine-Rolle in den Einstellungen).
    func hinzufuegen(_ e: ErkannteDrobo) {
        einstellungen.drobos.removeAll { $0.uuid == e.uuid }
        einstellungen.drobos.append(DroboEintrag(uuid: e.uuid, name: e.name.isEmpty ? "Drobo" : e.name))
        if auswahl.isEmpty { auswahl = e.uuid }
        einstellungenSpeichern()
    }

    // MARK: Drobos suchen (USB + lokales Netzwerk), nichts wird ohne Zustimmung uebernommen

    func drobosSuchen() {
        guard !sucheLaeuft else { return }
        sucheLaeuft = true; sucheInfo = nil
        let bekannt = Set(einstellungen.drobos.map { $0.uuid })
        let ausnehmen = Set(drobos.values.filter { $0.eingehaengt }.compactMap { $0.eintrag.netz?.host })     // eingehaengte DroboPro: keine zweite Sitzung
        Task.detached {
            let r = DroboKern.drobosSuchen(ausnehmen: ausnehmen)
            await MainActor.run {
                self.sucheLaeuft = false
                self.erkannte = r.usb.filter { !bekannt.contains($0.uuid) }
                self.lanErkannte = r.lan.map { LanDrobo(host: $0.host, luns: $0.luns.filter { !bekannt.contains($0.uuid) }) }.filter { !$0.luns.isEmpty }
                if let f = r.lanFehler { self.ablage.protokoll("Suche im Netzwerk: \(f)"); self.sucheInfo = String(localized: "Die Suche im lokalen Netzwerk ist nicht möglich. Läuft der Hilfsdienst?") }
                else if r.usb.isEmpty && r.lan.isEmpty { self.sucheInfo = String(localized: "Keine Drobo gefunden.") }
                self.aktualisieren()
            }
        }
    }

    func lanHinzufuegen(_ d: LanDrobo) {
        for (i, l) in d.luns.enumerated() {
            einstellungen.drobos.removeAll { $0.uuid == l.uuid }
            einstellungen.drobos.append(DroboEintrag(uuid: l.uuid, name: d.luns.count > 1 ? "DroboPro \(i + 1)" : "DroboPro", netz: NetzZiel(host: d.host, lun: l.lun)))
        }
        if let l = d.luns.first { auswahl = l.uuid }
        lanErkannte.removeAll { $0.host == d.host }
        einstellungenSpeichern()
    }

    // MARK: Netzwerk-Drobo per Adresse hinzufuegen (Adresse -> Suche -> Auswahl)

    func netzSuchen(_ adresse: String) {
        let host = adresse.trimmingCharacters(in: .whitespaces)
        netzTreffer = []; netzSucheFehler = nil; netzSucheLaeuft = true
        Task.detached {
            var treffer: [NetzLun] = []; var fehler: String?
            do { treffer = try netzEntdecken(host: host) } catch { fehler = Self.fehlerText(error) }
            await MainActor.run {
                self.netzSucheLaeuft = false; self.netzTreffer = treffer
                if let f = fehler { self.ablage.protokoll("Netzwerk-Drobo suchen (\(host)): \(f)"); self.netzSucheFehler = String(localized: "Keine Verbindung zu dieser Adresse. Zulässig sind nur Adressen im privaten Netz, zum Beispiel 192.168.1.20.") }
                else if treffer.isEmpty { self.netzSucheFehler = String(localized: "Auf dieser Drobo wurde kein eingerichtetes Volume gefunden.") }
            }
        }
    }

    func netzHinzufuegen(host: String, lun: NetzLun, name: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        einstellungen.drobos.removeAll { $0.uuid == lun.uuid }
        einstellungen.drobos.append(DroboEintrag(uuid: lun.uuid, name: name.isEmpty ? "DroboPro" : name, netz: NetzZiel(host: h, lun: lun.lun)))
        auswahl = lun.uuid
        einstellungenSpeichern()
    }

    func einstellungenSpeichern() { ablage.einstellungenSetzen(einstellungen); waechterNeu(); aktualisieren() }

    func imFinderOeffnen() { if let a = aktuell, a.eingehaengt { NSWorkspace.shared.open(URL(fileURLWithPath: a.ort)) } }

    func dienstRegistrieren() {
        do { try SMAppService.daemon(plistName: helferPlistName).register() } catch { meldung = Meldung(titel: "Hilfsdienst", text: "\(error)") }
        if SMAppService.daemon(plistName: helferPlistName).status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        aktualisieren()
    }

    /// Physisch weniger als 5 % frei (Capacity-Seite der Drobo): Warnung vor dem Schreiben.
    var physischKnapp: Bool { (aktuell?.hw?.kapazitaet?.freiAnteil).map { $0 < 0.05 } ?? false }

    var spotlightHinweisNoetig: Bool {
        guard let a = aktuell, a.eintrag.rolle == .arbeitsvolume, !einstellungen.spotlightAusgeschlossen else { return false }
        return (a.eingehaengt && !a.nurlesen) || (!a.eingehaengt && einstellungen.vorgabeSchreiben)
    }
}
