import AppKit
import SwiftUI
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
    var bremse: StatusBremse.Zustand = .bereit   // Netzwerk-Drobo: Abfrage pausiert (reagiert nicht / von anderem Rechner belegt) bis "Erneut pruefen"
    var luns: [LunEintrag] = []    // Netzwerk-Drobo: alle LUNs (virtuelle Platten) laut letztem Kontakt
    var lunEingehaengt: [Int: Bool] = [:]   // eingehaengte LUNs (Wert = nur lesen)

    /// Gesamtzustand fuer Uebersicht und Seitenleiste (Kern); Schwellen aus Seite 30 bei der DroboPro, sonst die Vorgabe 85/95 (USB: Seite 30 noch nicht gelesen).
    var hwZustand: Gesamtzustand? { hw.map { gesamtzustand($0, gelbProzent: netz?.gelbProzent ?? 85, rotProzent: netz?.rotProzent ?? 95, pruefungOK: merker.letztePruefung?.ok) } }

    var zustandText: String {
        if eintrag.netz != nil {
            if bremse == .reagiertNicht { return String(localized: "DroboPro reagiert nicht – bitte neu starten") }
            if bremse == .anderemRechner { return String(localized: "Diese DroboPro wird gerade von einem anderen Rechner benutzt.") }
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

/// Das eine Blatt (Sheet), das hoechstens gleichzeitig offen ist (Norm "ein Sheet"). Aktionen und Knoepfe setzen es ueber das Modell.
enum Blatt: Equatable, Identifiable {
    case schreiben, umbenennen(String), anleitung, restore, format(Int)
    var id: String { switch self { case .schreiben: return "schreiben"; case .umbenennen(let u): return "umbenennen-\(u)"; case .anleitung: return "anleitung"; case .restore: return "restore"; case .format(let l): return "format-\(l)" } }
}

struct Meldung: Identifiable { let id = UUID(); var titel: String; var text: String }

@MainActor
final class DroboModell: ObservableObject {
    let ablage = Datenablage()
    @Published var einstellungen: Einstellungen
    @Published var auswahl: String { didSet { ansichtSichern() } }
    @Published var drobos: [String: DroboAnsicht] = [:]
    @Published var protokoll: [Datenablage.Eintrag] = []
    @Published var tempo: [TempoMessung] = []
    @Published var hilfsdienst = String(localized: "unbekannt")
    @Published var festplattenzugriff = String(localized: "nicht geprüft")
    @Published var modul = ModulStatus(installiert: false, freigeschaltet: false)
    @Published var arbeit: String?
    @Published var meldung: Meldung?
    /// Rueckgaengig fuer jede Datenaenderung (Drobo-Liste, Namen, Rollen, Einstellungen); ein Manager fuer die ganze App.
    let undoManager = UndoManager()
    /// Gewaehlter Bereich der Seitenleiste; wird mit der gewaehlten Drobo wiederhergestellt (Datei ansicht.json im Datenordner, nie UserDefaults: die Demo teilt sie sonst mit der echten App).
    @Published var abschnitt: Abschnitt? { didSet { ansichtSichern() } }
    @Published var blatt: Blatt? { didSet { if blatt != oldValue { blattGeoeffnet() } } }
    /// Zuletzt bestaetigte Schreib-Kombination je Drobo (Datei bestaetigt.json im Datenordner, bewusst NICHT in den Einstellungen: Rueckgaengig darf sie nicht zuruecksetzen).
    @Published var bestaetigt: [String: BestaetigteKombination] = [:]
    /// Kaestchen "Ich habe eine aktuelle Sicherung" und Sperre des offenen Schreib-/Formatblatts; Uhr verstellbar (Steuerung `/uhr`).
    @Published var blattGesichert = false
    var blattStart = Date()
    var blattDauer = 0
    /// Blattart beim Oeffnen festgehalten (aendert sich nicht, solange das Blatt offen ist).
    var blattArtOffen: BlattArt = .kurz
    var uhrVersatz: TimeInterval = 0
    @Published var wegQuelle = ""
    @Published var wegZiel = ""
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
    /// Netzwerk-Drobos: Bremse je UUID (hoechstens alle 5 min, nie eingehaengt, nach einer Zeitueberschreitung Pause bis \"Erneut pruefen\"; die DroboPro haengt sonst).
    private var bremsen: [String: StatusBremse] = [:]
    private func bremse(_ uuid: String) -> StatusBremse { if let b = bremsen[uuid] { return b }; let b = StatusBremse(); bremsen[uuid] = b; return b }
    func erneutPruefen(_ uuid: String) { bremse(uuid).erneutPruefen(); aktualisieren(freigabe: true) }
    @Published var netzTreffer: [NetzLun] = []
    @Published var netzSucheLaeuft = false
    /// "Drobos suchen": im LAN gefundene, noch nicht eingerichtete Drobos (USB-Funde stehen in `erkannte`).
    @Published var lanErkannte: [LanDrobo] = []
    @Published var sucheLaeuft = false
    /// Netzwerk-Drobo: LUN, fuer die das Bestaetigungsblatt "Zum Schreiben einhaengen" gerade gilt (nil = die Haupt-LUN).
    @Published var schreibenLun: Int?
    /// UUIDs, die die letzte Suche fand und die schon eingerichtet sind ("schon hinzugefuegt" in "Drobos finden").
    @Published var sucheBekannt: Set<String> = []
    @Published var sucheInfo: String?
    @Published var netzSucheFehler: String?
    private var timer: Timer?
    private var vorher: [String: DroboAnsicht.Stufe] = [:]
    private var vorherSchwere: [String: Schweregrad] = [:]

    init() {
        var e = ablage.einstellungen()
        #if DEBUG
        if let es = DemoDaten.eintraege() { e.drobos = es }
        #endif
        einstellungen = e
        let z = Self.ansichtLesen(ablage.ordner)
        auswahl = z?.auswahl.flatMap { a in e.drobos.contains { $0.uuid == a } ? a : nil } ?? e.drobos.first?.uuid ?? ""
        abschnitt = z?.abschnitt.flatMap(Abschnitt.init(rawValue:)) ?? .uebersicht
        bestaetigt = FileManager.default.contents(atPath: ablage.ordner + "/bestaetigt.json").flatMap { try? JSONDecoder().decode([String: BestaetigteKombination].self, from: $0) } ?? [:]
        #if DEBUG
        if let s = DemoDaten.seite { abschnitt = s }
        #endif
    }

    private struct AnsichtZustand: Codable { var abschnitt: String?; var auswahl: String? }
    private static func ansichtLesen(_ ordner: String) -> AnsichtZustand? {
        FileManager.default.contents(atPath: ordner + "/ansicht.json").flatMap { try? JSONDecoder().decode(AnsichtZustand.self, from: $0) }
    }
    func ansichtSichern() {
        guard let d = try? JSONEncoder().encode(AnsichtZustand(abschnitt: abschnitt?.rawValue, auswahl: auswahl)) else { return }
        try? FileManager.default.createDirectory(atPath: ablage.ordner, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: ablage.ordner + "/ansicht.json"), options: .atomic)
    }

    var aktuell: DroboAnsicht? { drobos[auswahl] }
    /// Schlimmster Zustand aller Drobos fuer die Menueleiste (nil = keine Statusdaten).
    var gesamtSchwere: Schweregrad? { drobos.values.compactMap { $0.hw?.schwere }.max() }
    var liste: [DroboAnsicht] { einstellungen.drobos.compactMap { drobos[$0.uuid] } }

    func kern(_ uuid: String) -> Kern { var k = Kern(uuid: uuid); k.ablage = ablage; return k }

    // MARK: Start / Aktualisieren

    private var gestartet = false
    /// Aktivierungsregel der App: Dock-Symbol (regular) oder nur Menueleiste (accessory).
    static func aktivierung(nurMenueleiste: Bool) -> NSApplication.ActivationPolicy { nurMenueleiste ? .accessory : .regular }
    func aktivierungAnwenden() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DROBO_DEMO_HINTEN"] != nil { return }   // Testlauf bleibt unsichtbar (kein Dock-Symbol)
        #endif
        NSApp.setActivationPolicy(Self.aktivierung(nurMenueleiste: einstellungen.nurMenueleiste))
    }

    /// Wird beim Erscheinen des Fensters gerufen; die App lebt nach dem Schliessen weiter (Menueleiste), das Fenster kann also mehrmals erscheinen: nur einmal starten.
    func starten() {
        guard !gestartet else { return }
        gestartet = true
        aktivierungAnwenden()
        #if DEBUG
        Steuerung.startenWennGewuenscht(self)
        if ProcessInfo.processInfo.environment["DROBO_DEMO_HINTEN"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.windows.forEach { $0.orderOut(nil) } } }
        if let b = DemoDaten.blatt { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.blatt = b } }
        #endif
        anmeldeStart = SMAppService.mainApp.status == .enabled
        // Ruhezustand/Ausschalten: iSCSI-Volumes vorher aushaengen, damit die Sitzungen mit Logout enden (sonst Leichen an der DroboPro). Synchron: danach ist es zu spaet.
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: nil) { [ablage] _ in
                do { try iscsiAlleAushaengen(meldung: { ablage.protokoll("Netzwerk-Drobo: \($0) (Ruhezustand/Ausschalten)") }) }
                catch { ablage.protokoll("Netzwerk-Drobo: Aushängen vor Ruhezustand/Ausschalten fehlgeschlagen: \(error)") }
            }
        }
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
        #if DEBUG
        if var d = DemoDaten.ansichten() {
            // Demo folgt den Einstellungen (Umbenennen, Entfernen, Rueckgaengig wirken sichtbar), die Statusdaten bleiben die erfundenen
            d = d.filter { u, _ in einstellungen.drobos.contains { $0.uuid == u } }
            for e in einstellungen.drobos where d[e.uuid] != nil { d[e.uuid]?.eintrag = e }
            uebernehmen(d, modul: ModulStatus(installiert: true, freigeschaltet: !DemoDaten.problem), dienst: String(localized: "bereit")); return
        }
        #endif
        let ds = einstellungen.drobos
        let alt = drobos
        let jetzt = Date()
        let eingehaengteHosts = Set(drobos.values.filter { $0.eingehaengt || !$0.lunEingehaengt.isEmpty }.compactMap { $0.eintrag.netz?.host })
        let netzLesen = Set(ds.filter { d in d.netz.map { nz in bremse(d.uuid).darfAbfragen(eingehaengt: eingehaengteHosts.contains(nz.host), jetzt: jetzt) } ?? false }.map { $0.uuid })
        let bremsenKopie = bremsen
        Task.detached { [ablage] in
            var neu: [String: DroboAnsicht] = [:]
            var zugriff: Bool?
            var ziele: [String: NetzZiel] = [:]      // neue Adresse/IQN je Netzwerk-Drobo (wird nach dem Lauf gespeichert)
            for d in ds {
                var k = Kern(uuid: d.uuid); k.ablage = ablage
                var a = DroboAnsicht(eintrag: d)
                if let nz = d.netz {            // Netzwerk-Drobo: eigener Weg, kein Geraeteknoten
                    let v = alt[d.uuid]
                    (a.hw, a.netz, a.netzStand, a.netzFehler) = (v?.hw, v?.netz, v?.netzStand, v?.netzFehler)
                    a.luns = v?.luns ?? []
                    for l in Set(a.luns.map(\.lun)).union([nz.lun]) { if let e = netzEinhaengung(lun: l) { a.lunEingehaengt[l] = e.nurlesen } }
                    let br = bremsenKopie[d.uuid]
                    if let e = netzEinhaengung(lun: nz.lun) {      // eingehaengt: keine zweite Sitzung oeffnen
                        if netzLesen.contains(d.uuid) { br?.ergebnis(nil) }      // reservierte Abfrage zurueckgeben
                        a.verbunden = true; a.eingehaengt = true; a.nurlesen = e.nurlesen; a.ort = e.ort; a.treiber = "iSCSI"
                        var s = statfs()
                        if statfs(e.ort, &s) == 0 { a.gesamt = UInt64(s.f_blocks) * UInt64(s.f_bsize); a.belegt = a.gesamt - UInt64(s.f_bfree) * UInt64(s.f_bsize) }
                    } else if netzLesen.contains(d.uuid) {
                        do {
                            let (st, info) = try netzStatusLesen(host: nz.host); (a.hw, a.netz, a.netzStand, a.netzFehler) = (st, info, Date(), nil)
                            br?.ergebnis(nil)       // Status gelesen: die Sitzung ist zu; Kontakt/LUN-Liste folgt nacheinander (nie zwei Sitzungen gleichzeitig)
                            let k = Self.netzKontakt(nz); if !k.luns.isEmpty { a.luns = k.luns }
                            if let n = k.ziel { ziele[d.uuid] = n }
                        } catch {
                            br?.ergebnis(error)
                            (a.hw, a.netzFehler) = (nil, Self.fehlerText(error))
                            // Haengt die DroboPro oder gehoert sie einem anderen Rechner, wird NICHT weiter angeklopft (auch nicht fuer die Adresssuche)
                            if br?.zustand ?? .bereit == .bereit, let n = Self.netzAdresseNachfuehren(nz, ablage: ablage, ausnehmen: eingehaengteHosts) { ziele[d.uuid] = n }
                        }
                    }
                    a.bremse = br?.zustand ?? .bereit
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
                self.zieleUebernehmen(ziele)
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

    /// Skala der Rundinstrumente: nächste runde Größe (1-2-5) über der Spitze, wächst nur (Kern: tempoSkala).
    var tempoSkala: Double {
        DroboKern.tempoSkala(spitze: max(tempoSpitze, tempoSchreibenLive ?? 0, tempoLesenLive ?? 0, tempo.filter { $0.uuid == tempoZiel?.eintrag.uuid }.map { $0.mbProSekunde }.max() ?? 0))
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
        if p.runModal() == .OK, let u = p.url { aendern(String(localized: "Sicherungsort ändern")) { $0.sicherungOrt = u.path } }
    }

    /// Erkannte Drobo einrichten (Rolle Arbeitsvolume; Time-Machine-Rolle in den Einstellungen).
    func hinzufuegen(_ e: ErkannteDrobo) {
        aendern(String(localized: "Drobo hinzufügen")) {
            $0.drobos.removeAll { $0.uuid == e.uuid }
            $0.drobos.append(DroboEintrag(uuid: e.uuid, name: e.name.isEmpty ? "Drobo" : e.name))
        }
        if auswahl.isEmpty { auswahl = e.uuid }
        sucheBekannt.insert(e.uuid)
    }

    // MARK: Drobos suchen (USB + lokales Netzwerk), nichts wird ohne Zustimmung uebernommen

    func drobosSuchen() {
        #if DEBUG
        guard DemoDaten.art == nil else { return }   // Demo fasst kein Netz und kein Geraet an
        #endif
        guard !sucheLaeuft else { return }
        sucheLaeuft = true; sucheInfo = nil
        let bekannt = Set(einstellungen.drobos.map { $0.uuid })
        let ausnehmen = Set(drobos.values.filter { $0.eingehaengt }.compactMap { $0.eintrag.netz?.host })     // eingehaengte DroboPro: keine zweite Sitzung
        Task.detached {
            let r = DroboKern.drobosSuchen(ausnehmen: ausnehmen)
            await MainActor.run {
                self.sucheLaeuft = false
                self.sucheBekannt = Set((r.usb.map(\.uuid) + r.lan.flatMap { $0.luns.map(\.uuid) }).filter { bekannt.contains($0) })
                self.erkannte = r.usb.filter { !bekannt.contains($0.uuid) }
                self.lanErkannte = r.lan.map { LanDrobo(host: $0.host, luns: $0.luns.filter { !bekannt.contains($0.uuid) }) }.filter { !$0.luns.isEmpty }
                if let f = r.lanFehler { self.ablage.protokoll("Suche im Netzwerk: \(f)"); self.sucheInfo = String(localized: "Die Suche im lokalen Netzwerk ist nicht möglich. Läuft der Hilfsdienst?") }
                else if r.usb.isEmpty && r.lan.isEmpty { self.sucheInfo = String(localized: "Keine Drobo gefunden.") }
                self.aktualisieren()
            }
        }
    }

    /// Ein Eintrag je Drobo (alle LUNs darin), nicht je LUN.
    func lanHinzufuegen(_ d: LanDrobo) {
        guard let erste = d.luns.first else { return }
        let l = d.luns.map { NetzLunEintrag(lun: $0.lun, uuid: $0.uuid, name: String(localized: "Volume \($0.lun + 1)")) }
        aendern(String(localized: "Drobo hinzufügen")) {
            $0.drobos.removeAll { e in d.luns.contains { $0.uuid == e.uuid } }
            $0.drobos.append(DroboEintrag(uuid: erste.uuid, name: "DroboPro", netz: NetzZiel(host: d.host, lun: erste.lun, iqn: nil, luns: l)))
        }
        auswahl = erste.uuid
        sucheBekannt.formUnion(d.luns.map(\.uuid))
        lanErkannte.removeAll { $0.host == d.host }
    }

    // MARK: Netzwerk-Drobo per Adresse hinzufuegen (Adresse -> Suche -> Auswahl)

    func netzSuchen(_ adresse: String) {
        #if DEBUG
        guard DemoDaten.art == nil else { return }   // Demo fasst kein Netz an
        #endif
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
        aendern(String(localized: "Drobo hinzufügen")) {
            $0.drobos.removeAll { $0.uuid == lun.uuid }
            $0.drobos.append(DroboEintrag(uuid: lun.uuid, name: name.isEmpty ? "DroboPro" : name, netz: NetzZiel(host: h, lun: lun.lun)))
        }
        auswahl = lun.uuid
    }

    // MARK: Rueckgaengig (jede Datenaenderung der App laeuft hier durch)

    /// Aendert die Einstellungen (Drobo-Liste, Namen, Rollen, Orte ...) und merkt den Vorzustand im UndoManager. Rueckgaengig stellt ihn her und merkt seinerseits "Wiederholen".
    func aendern(_ name: String, _ f: (inout Einstellungen) -> Void) {
        var neu = einstellungen; f(&neu); einstellungenSetzen(neu, name)
    }
    private func einstellungenSetzen(_ neu: Einstellungen, _ name: String) {
        let alt = einstellungen
        guard alt != neu else { return }
        einstellungen = neu; einstellungenSpeichern()
        if alt.nurMenueleiste != neu.nurMenueleiste { aktivierungAnwenden() }
        undoManager.registerUndo(withTarget: self) { $0.einstellungenSetzen(alt, name) }
        undoManager.setActionName(name)
    }
    /// Bindung fuer ein Einstellungsfeld, dessen Aenderung rueckgaengig machbar ist.
    func binding<T>(_ kp: WritableKeyPath<Einstellungen, T>, _ name: String) -> Binding<T> {
        Binding(get: { self.einstellungen[keyPath: kp] }, set: { v in self.aendern(name) { $0[keyPath: kp] = v } })
    }
    func entfernen(_ uuid: String) {
        guard einstellungen.drobos.count > 1 else { return }
        aendern(String(localized: "Drobo entfernen")) { $0.drobos.removeAll { $0.uuid == uuid } }
    }

    // MARK: Schreib- und Formatblatt: Blattart, Sperre, Bestaetigen

    func jetzt() -> Date { Date().addingTimeInterval(uhrVersatz) }
    var bestaetigtSchluessel: String { (aktuell?.eintrag.uuid ?? "") + (aktuell?.eintrag.netz.map { "#\(schreibenLun ?? $0.lun)" } ?? "") }
    /// Volles Blatt mit Sperre oder kurze Zeile (Kern: schreibBlattArt).
    var schreibBlattArt: BlattArt {
        DroboKern.schreibBlattArt(erprobt: erprobtErgebnis(.schreiben).istErprobt, zuletzt: bestaetigt[bestaetigtSchluessel], build: aktuell?.hw?.firmwareBuild, anschluss: anschluss, unsauber: aktuell?.merker.offenePruefung != nil)
    }
    private func blattGeoeffnet() {
        blattGesichert = false; blattStart = jetzt()
        switch blatt { case .schreiben: blattArtOffen = schreibBlattArt; blattDauer = blattArtOffen.sperre; case .format: blattDauer = sperrSekunden; default: blattDauer = 0 }
    }
    func sperreRest(_ zeit: Date? = nil) -> Int { DroboKern.sperreRest(start: blattStart, dauer: blattDauer, jetzt: zeit ?? jetzt()) }
    var schreibenFreigegeben: Bool { !einstellungen.sicherungOrt.isEmpty && (erprobtErgebnis(.schreiben).istErprobt || blattGesichert) }

    private func bestaetigtSichern() {
        guard let d = try? JSONEncoder().encode(bestaetigt) else { return }
        try? FileManager.default.createDirectory(atPath: ablage.ordner, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: ablage.ordner + "/bestaetigt.json"), options: .atomic)
    }

    /// Bestaetigen im Schreibblatt (Knopf UND Steuerung): erst nach der Sperre, mit Sicherungsort und (bei nicht erprobter Kombination) dem Sicherungs-Kaestchen. Rueckgabe: Grund der Ablehnung.
    func schreibenBestaetigen() -> String? {
        guard blatt == .schreiben else { return String(localized: "Kein Blatt offen.") }
        let r = sperreRest(); if r > 0 { return String(localized: "Gesperrt, noch \(r) s.") }
        guard schreibenFreigegeben else { return String(localized: "Sicherungsort oder Sicherungs-Bestätigung fehlt.") }
        let l = schreibenLun
        bestaetigt[bestaetigtSchluessel] = BestaetigteKombination(build: aktuell?.hw?.firmwareBuild, anschluss: anschluss); bestaetigtSichern()
        blatt = nil
        #if DEBUG
        if DemoDaten.art != nil { return nil }   // Demo fasst kein Geraet an
        #endif
        if let l { lunEinhaengen(l, schreiben: true) } else if aktuell?.eingehaengt == true { neuZumSchreiben() } else { einhaengen(schreiben: true) }
        return nil
    }

    /// Bestaetigen im Formatblatt (immer volles Blatt, Sperre, Namenspruefung).
    func formatBestaetigen(lun: Int, name: String) -> String? {
        guard blatt == .format(lun) else { return String(localized: "Kein Blatt offen.") }
        let n = name.trimmingCharacters(in: .whitespaces)
        let r = sperreRest(); if r > 0 { return String(localized: "Gesperrt, noch \(r) s.") }
        guard !n.isEmpty, !n.contains(":"), n.utf8.count <= 27 else { return String(localized: "Der Name ist ungültig.") }
        guard erprobtErgebnis(.formatieren).istErprobt || blattGesichert else { return String(localized: "Sicherungsort oder Sicherungs-Bestätigung fehlt.") }
        blatt = nil
        #if DEBUG
        if DemoDaten.art != nil { return nil }
        #endif
        lunFormatieren(lun, name: n)
        return nil
    }

    // MARK: Erprobt (Hinweis im Bestaetigungsblatt)

    /// Anschluss der gewaehlten Drobo: USB (Geraeteknoten) oder die Schnittstelle der Route zur iSCSI-Adresse (WLAN/Kabel).
    var anschluss: Anschluss {
        #if DEBUG
        if let a = DemoDaten.anschluss, aktuell?.eintrag.netz != nil { return a }   // Demo: Anschluss vorgegeben statt gemessen
        #endif
        return aktuell?.eintrag.netz.map { anschlussNetz(host: $0.host) } ?? .usb
    }
    func erprobtErgebnis(_ aktion: ErprobtAktion) -> ErprobtErgebnis {
        return erprobt(modell: aktuell?.hw?.modell ?? "", build: aktuell?.hw?.firmwareBuild, anschluss: anschluss, aktion: aktion)
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
