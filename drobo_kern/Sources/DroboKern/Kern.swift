import Foundation

public let vorgabeOrt = "/private/tmp/drobo_mnt"
/// Einhaengeort-Kennung: /Volumes/<Volumename> (der Hilfsdienst legt den Ordner an).
public let vorgabeVolumes = "/Volumes"

public struct ModulStatus: Equatable { public var installiert: Bool; public var freigeschaltet: Bool; public init(installiert: Bool, freigeschaltet: Bool) { self.installiert = installiert; self.freigeschaltet = freigeschaltet } }

/// `pluginkit -m -i <Kennung>`: Zeile mit Praefix "+" = freigeschaltet, "-" = installiert aber nicht gewaehlt, leer = unbekannt.
public func modulStatus() -> ModulStatus {
    let (_, out) = ausfuehren("/usr/bin/pluginkit", ["-m", "-i", modulKennung])
    let zeile = out.split(separator: "\n").first { $0.contains(modulKennung) }.map(String.init) ?? ""
    return ModulStatus(installiert: !zeile.isEmpty, freigeschaltet: zeile.trimmingCharacters(in: .whitespaces).hasPrefix("+"))
}

@discardableResult
public func ausfuehren(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (127, "\(exe): \(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

public struct Zustand {
    public enum Verbindung { case nichtAngeschlossen, angeschlossen(Medium), eingehaengt(Medium, Einhaengung) }
    public var uuid: String
    public var verbindung: Verbindung
    public var modul: ModulStatus
    public var freigabe: Modus?

    public var kurz: String {
        switch verbindung {
        case .nichtAngeschlossen: return "nicht angeschlossen"
        case .angeschlossen: return "angeschlossen, nicht eingehaengt"
        case .eingehaengt(_, let e):
            let t: String; switch e.treiber { case .kernel: t = "Kernel"; case .hfsdrobo: t = "hfsdrobo"; case .andere(let s): t = s }
            return "eingehaengt \(e.nurlesen ? "ro" : "rw") durch \(t)"
        }
    }

    public var json: [String: Any] {
        var j: [String: Any] = ["uuid": uuid, "zustand": kurz,
                                "modul_installiert": modul.installiert, "modul_freigeschaltet": modul.freigeschaltet,
                                "freigabe": freigabe?.rawValue ?? NSNull()]
        switch verbindung {
        case .nichtAngeschlossen: j["verbindung"] = "nicht_angeschlossen"
        case .angeschlossen(let m): j["verbindung"] = "angeschlossen"; j["geraet"] = m.geraet
        case .eingehaengt(let m, let e):
            j["verbindung"] = "eingehaengt"; j["geraet"] = m.geraet; j["ort"] = e.ort
            j["nurlesen"] = e.nurlesen
            switch e.treiber { case .kernel: j["treiber"] = "kernel"; case .hfsdrobo: j["treiber"] = "hfsdrobo"; case .andere(let s): j["treiber"] = s }
        }
        return j
    }

    public var text: String {
        var z = ["Volume:    \(uuid)", "Zustand:   \(kurz)"]
        switch verbindung {
        case .nichtAngeschlossen: break
        case .angeschlossen(let m): z.append("Geraet:    \(m.geraet)")
        case .eingehaengt(let m, let e): z.append("Geraet:    \(m.geraet)"); z.append("Ort:       \(e.ort)")
        }
        z.append("Modul:     " + (!modul.installiert ? "nicht installiert" : modul.freigeschaltet ? "installiert, freigeschaltet" : "installiert, NICHT freigeschaltet"))
        z.append("Freigabe:  " + (freigabe?.rawValue ?? "kein Eintrag"))
        return z.joined(separator: "\n")
    }
}

/// Alles, was sich im Test austauschen laesst, steht hier; die Vorgaben sind die echten Systemaufrufe.
public struct Kern {
    public var uuid: String
    /// Freigabeliste: Datei (Tests, DROBO_FREIGABE) oder Standard = ueber den Hilfsdienst (Container ist fuer die Shell gesperrt).
    public var listeLesen: (String) throws -> Modus?
    public var listeSetzen: (String, String, UInt64?) throws -> Void   // Modus: nurlesen|schreiben|entfernen
    public var modul: () -> ModulStatus
    public var home: [String]
    public var ablage: Datenablage = Datenablage()
    /// Einhaengeort "/Volumes" = Ordner /Volumes/<Volumename> legt der Hilfsdienst an (Finder-Seitenleiste) und entfernt ihn beim Aushaengen.
    public var zugriffPruefenRPC: (String) -> String? = { helferZugriffPruefen(uuid: $0) }
    public var ordnerAnlegen: (String) throws -> String = { try helferOrdnerAnlegen(uuid: $0) }
    public var ordnerEntfernen: (String) -> String? = { helferOrdnerEntfernen(uuid: $0) }
    /// Messung/Test: Partitionsgroesse fuer die Volumeende-Bestimmung bei Geraeten kommt aus DiskArbitration.
    /// Hilfsdienst (freigeben|zurueckgeben): nil = ok, sonst Fehlertext. Nie fatal: reicht der Zugriff trotzdem, geht es weiter.
    public var helfer: (String, String) -> String? = { helferAufruf($0, uuid: $1) }
    public var meldung: (String) -> Void = { FileHandle.standardError.write(Data("HINWEIS: \($0)\n".utf8)) }

    public static func umgebung(_ k: String) -> String? { ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 } }

    /// Volume: Argument, sonst Umgebung DROBO_UUID, sonst die erste eingerichtete Drobo der Einstellungen, sonst leer (= keine eingerichtet).
    public init(uuid: String? = nil,
                freigabePfad: String? = Kern.umgebung("DROBO_FREIGABE"),
                modul: @escaping () -> ModulStatus = modulStatus,
                home: [String] = [NSHomeDirectory(), ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]) {
        self.uuid = (uuid ?? Kern.umgebung("DROBO_UUID") ?? Datenablage().einstellungen().drobos.first?.uuid ?? "").uppercased()
        if let p = freigabePfad {
            listeLesen = { try Freigabe.lesen(uuid: $0, pfad: p) }
            listeSetzen = { $1 == "entfernen" ? try Freigabe.entfernen(uuid: $0, pfad: p) : try Freigabe.setzen(uuid: $0, modus: Modus(rawValue: $1)!, maxBytes: $2, pfad: p) }
        } else {
            listeLesen = { try helferFreigabeLesen(uuid: $0) }
            listeSetzen = { try helferFreigabeSetzen(uuid: $0, modus: $1, maxBytes: $2 ?? 0) }
        }
        self.modul = modul; self.home = home
    }

    public func zustand(mitFreigabe: Bool = true) throws -> Zustand {
        let fr = mitFreigabe ? try listeLesen(uuid) : nil
        let v: Zustand.Verbindung
        if let m = finden(uuid: uuid) {
            if let e = einhaengungen()[m.geraet] { v = .eingehaengt(m, e) } else { v = .angeschlossen(m) }
        } else { v = .nichtAngeschlossen }
        return Zustand(uuid: uuid, verbindung: v, modul: modul(), freigabe: fr)
    }

    public func freigabeSetzen(_ modus: Modus) throws {
        let z = try zustand()
        var mb: UInt64? = nil
        switch z.verbindung {
        case .angeschlossen(let m), .eingehaengt(let m, _): mb = m.groesse + (1 << 30)
        case .nichtAngeschlossen: break
        }
        try listeSetzen(uuid, modus.rawValue, mb)
    }

    public func freigabeEntfernen() throws { try listeSetzen(uuid, "entfernen", nil) }

    /// Ort liegt unter Home? Aufgeloest ueber Symlinks (der naechste vorhandene Vorfahr), damit /var/.. oder Links nicht taeuschen.
    public static func aufgeloest(_ pfad: String) -> String {
        var url = URL(fileURLWithPath: pfad).standardizedFileURL; var rest: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { rest.insert(url.lastPathComponent, at: 0); url.deleteLastPathComponent() }
        return rest.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    func unterHome(_ ort: String) -> Bool {
        let o = Kern.aufgeloest(ort)
        return home.contains { let h = Kern.aufgeloest($0); return o == h || o.hasPrefix(h + "/") }
    }

    /// Rolle dieser Drobo laut Einstellungen; unbekannte UUID = Arbeitsvolume.
    public var rolle: Rolle { ablage.einstellungen().drobos.first { $0.uuid == uuid }?.rolle ?? .arbeitsvolume }

    @discardableResult
    public func einhaengen(modus: Modus = .nurlesen, ort: String = vorgabeOrt) throws -> Einhaengung {
        if rolle == .timemachine { throw AppFehler.nurAnzeige("Diese Drobo ist als Time-Machine-Ziel eingetragen und wird ueber unser Modul nie eingehaengt") }
        if unterHome(ort) { throw Fehler.ortUnterHome(ort) }
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        if let e = einhaengungen()[m.geraet] { throw Fehler.eingehaengt("\(m.geraet) auf \(e.ort) (\(e.nurlesen ? "ro" : "rw"))") }
        guard let f = try listeLesen(uuid) else { throw Fehler.keineFreigabe(uuid) }
        if modus == .schreiben && f != .schreiben {
            throw Fehler.freigabeReichtNicht("Freigabe fuer \(uuid) steht auf nurlesen, Schreiben verlangt. Aendern: drobo freigabe schreiben")
        }
        let mod = modul()
        if !mod.installiert { throw Fehler.modul("Modul \(modulKennung) nicht installiert (tools/install_module.sh)") }
        if !mod.freigeschaltet { throw Fehler.modul("Modul \(modulKennung) nicht freigeschaltet (Systemeinstellungen, Betreiber)") }
        if let h = helfer("freigeben", uuid) { meldung("Hilfsdienst: \(h)") }
        let t = try torpruefung(pfad: m.rohgeraet)
        if !t.ok { throw Fehler.tor(t.probleme) }
        // Tor 2: offene Pruefung (Trennung im Schreibzustand, fehlgeschlagene Nachpruefung) VOR jedem Einhaengen, auch nurlesen
        var mk = ablage.merker(uuid)
        if mk.rwAktiv && einhaengungen()[m.geraet] == nil && mk.offenePruefung == nil {
            mk.offenePruefung = "Beim letzten Mal war das Laufwerk im Schreibzustand eingehaengt und wurde nicht sauber ausgehaengt"
            ablage.merkerAendern(uuid) { $0.rwAktiv = false; $0.offenePruefung = mk.offenePruefung }
        }
        if let grund = mk.offenePruefung {
            let r = try nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse)
            ablage.merkerAendern(uuid) { $0.letztePruefung = r; if r.ok { $0.offenePruefung = nil } }
            ablage.protokoll("Pruefung vor dem Einhaengen (\(grund)): " + (r.ok ? "in Ordnung" : "NICHT in Ordnung: " + r.probleme.joined(separator: "; ")))
            if !r.ok { throw AppFehler.pruefung("Pruefung vor dem Einhaengen nicht bestanden (\(grund)): " + r.probleme.joined(separator: "; ")) }
        }
        var sicherungsOrdner: String? = nil
        if modus == .schreiben {
            let e = ablage.einstellungen()
            try sicherungsOrtPruefen(e.sicherungOrt, quelle: m.rohgeraet)   // vor allem anderen: ohne gueltigen Ort nie schreiben
            let s = try metadatenSichern(quelle: m.rohgeraet, ort: e.sicherungOrt, uuid: uuid, anzahl: e.sicherungAnzahl, partitionsgroesse: m.groesse)
            sicherungsOrdner = s.ordner
            ablage.protokoll("Metadaten gesichert: \(s.ordner)")
        }
        var ort = ort; let ueberDienst = ort == vorgabeVolumes
        if ueberDienst { ort = try ordnerAnlegen(uuid) } else { try FileManager.default.createDirectory(atPath: ort, withIntermediateDirectories: true) }
        let (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdrobo", "-o", modus == .nurlesen ? "rdonly" : "rw", m.geraet, ort])
        guard rc == 0 else { if ueberDienst { _ = ordnerEntfernen(uuid) }; throw Fehler.mountFehlgeschlagen(out.isEmpty ? "Exit \(rc)" : out) }
        guard let e = einhaengungen()[m.geraet] else { throw Fehler.mountFehlgeschlagen("mount meldete Erfolg, Mount-Tabelle zeigt \(m.geraet) nicht") }
        if modus == .nurlesen && !e.nurlesen {
            _ = ausfuehren("/sbin/umount", [ort])
            throw Fehler.mountFehlgeschlagen("Mount ist NICHT read-only gemeldet -> ausgehaengt")
        }
        if modus == .schreiben {
            ablage.merkerAendern(uuid) { $0.rwAktiv = true; $0.bsd = m.bsd; $0.ort = ort; $0.seit = jetztText(); $0.letzteSicherung = sicherungsOrdner }
        } else { ablage.merkerAendern(uuid) { $0.bsd = m.bsd } }
        ablage.protokoll("Eingehaengt (\(modus == .schreiben ? "schreiben" : "nur lesen")): \(ort)")
        return e
    }

    /// Aushaengen; war das Volume im Schreibzustand, folgt VOR der Rueckgabe des Geraeteknotens die Nachpruefung (Ergebnis im Merker + Rueckgabe).
    @discardableResult
    public func aushaengen() throws -> PruefErgebnis? {
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        guard let e = einhaengungen()[m.geraet] else { throw Fehler.nichtEingehaengt(uuid) }
        var (rc, out) = ausfuehren("/sbin/umount", [e.ort])
        if rc != 0 { (rc, out) = ausfuehren("/usr/sbin/diskutil", ["unmount", e.ort]) }
        if rc != 0 || einhaengungen()[m.geraet] != nil { throw Fehler.aushaengenFehlgeschlagen(out) }
        if e.ort.hasPrefix(vorgabeVolumes + "/"), let f = ordnerEntfernen(uuid) { meldung("Ordner \(e.ort) bleibt stehen: \(f)") }
        var pruef: PruefErgebnis? = nil
        if ablage.merker(uuid).rwAktiv {
            ablage.merkerAendern(uuid) { $0.rwAktiv = false }
            let r = (try? nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse)) ?? { var x = PruefErgebnis(); x.zeit = jetztText(); x.probleme = ["Pruefung nicht moeglich (Geraet nicht lesbar)"]; return x }()
            ablage.merkerAendern(uuid) { $0.letztePruefung = r; $0.offenePruefung = r.ok ? nil : "Pruefung nach dem Schreiben nicht bestanden" }
            ablage.protokoll("Ausgehaengt, Pruefung: " + (r.ok ? "in Ordnung" : "NICHT in Ordnung: " + r.probleme.joined(separator: "; ")))
            pruef = r
        } else { ablage.protokoll("Ausgehaengt") }
        if let h = helfer("zurueckgeben", uuid) { meldung("Hilfsdienst: \(h). Knoten bleibt beim Nutzer; zurueck: sudo chown root:operator \(m.geraet) \(m.rohgeraet)") }
        return pruef
    }

    /// Ordner wegsichern (Quelle muss auf der eingehaengten Drobo liegen, Ziel nie darauf).
    public func wegsichern(quelle: String, ziel: String, fortschritt: ((String) -> Void)? = nil, abbrechen: () -> Bool = { false }) throws -> WegsichernBericht {
        guard let m = finden(uuid: uuid), let e = einhaengungen()[m.geraet] else { throw Fehler.nichtEingehaengt(uuid) }
        let q = Kern.aufgeloest(quelle), o = Kern.aufgeloest(e.ort)
        guard q == o || q.hasPrefix(o + "/") else { throw AppFehler.wegsichern("Quellordner liegt nicht auf der eingehaengten Drobo (\(e.ort))") }
        let b = try ordnerWegsichern(quelle: quelle, ziel: ziel, verboten: [e.ort], fortschritt: fortschritt, abbrechen: abbrechen)
        ablage.protokoll("Wegsichern \((quelle as NSString).lastPathComponent) nach \(ziel): " + b.text)
        return b
    }

    public func tempoTesten(schreiben: Bool = false, mib: Int = 64) throws -> TempoMessung {
        guard let m = finden(uuid: uuid), let e = einhaengungen()[m.geraet] else { throw Fehler.nichtEingehaengt(uuid) }
        if schreiben {
            let mk = ablage.merker(uuid)
            guard !e.nurlesen, mk.rwAktiv else { throw AppFehler.tempotest("Schreib-Tempotest nur bei Einhaengen zum Schreiben") }
            guard let s = mk.letzteSicherung, FileManager.default.fileExists(atPath: s + "/" + markerName) else { throw AppFehler.tempotest("Schreib-Tempotest nur mit vorhandener Metadaten-Sicherung") }
            let r = try tempoSchreiben(ort: e.ort, uuid: uuid, mib: mib, ablage: ablage)
            ablage.protokoll(String(format: "Tempotest schreiben: %.1f MB/s", r.mbProSekunde)); return r
        }
        let r = try tempoLesen(ort: e.ort, uuid: uuid, ablage: ablage)
        ablage.protokoll(String(format: "Tempotest lesen: %.1f MB/s", r.mbProSekunde)); return r
    }

    /// Festplattenzugriff des Hilfsdienstes (wirkungslose Probe). nil = in Ordnung.
    public func zugriffPruefen() -> String? { zugriffPruefenRPC(uuid) }

    /// Belegung aus dem Volume-Header (nur lesend, Volume darf ausgehaengt sein; Geraetezugang ueber den Dienst). Wird im Merker abgelegt.
    @discardableResult
    public func belegungLesen() throws -> Belegung {
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        if let h = helfer("freigeben", uuid) { meldung("Hilfsdienst: \(h)") }
        defer { _ = helfer("zurueckgeben", uuid) }
        let r = try belegungAusHeader(pfad: m.rohgeraet)
        ablage.merkerAendern(uuid) { $0.belegung = r }
        return r
    }

    // MARK: Sicherung zurueckspielen (nur ausgehaengt)

    /// Eigene Sicherungen dieser Drobo, neueste zuerst (Ordnernamen).
    public func sicherungen() -> [String] { eigeneSicherungen(ort: ablage.einstellungen().sicherungOrt, uuid: uuid).reversed() }

    private func restoreZiel(_ name: String) throws -> (Medium, String) {
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        if einhaengungen()[m.geraet] != nil { throw AppFehler.sicherung("Das Laufwerk ist eingehaengt. Zuerst aushaengen.") }
        guard sicherungen().contains(name) else { throw AppFehler.sicherung("Unbekannte Sicherung \(name)") }
        return (m, ablage.einstellungen().sicherungOrt + "/" + name)
    }

    /// Probelauf: schreibt nie.
    public func zurueckspielenProbe(sicherung name: String) throws -> RestoreProbe {
        let (m, d) = try restoreZiel(name)
        if let h = helfer("freigeben", uuid) { meldung("Hilfsdienst: \(h)") }
        defer { _ = helfer("zurueckgeben", uuid) }
        let p = try DroboKern.zurueckspielenProbe(geraet: m.rohgeraet, sicherung: d, uuid: uuid)
        ablage.protokoll("Probelauf Zurueckspielen \(name): \(p.gesamt) abweichende Bloecke")
        return p
    }

    /// Schreibt die Sicherung zurueck. Aufrufer holt vorher die ausdrueckliche zweite Bestaetigung.
    @discardableResult
    public func zurueckspielen(sicherung name: String, schreibgroesse: Int = standardSchreiben) throws -> PruefErgebnis {
        let (m, d) = try restoreZiel(name)
        if let h = helfer("freigeben", uuid) { meldung("Hilfsdienst: \(h)") }
        defer { _ = helfer("zurueckgeben", uuid) }
        ablage.protokoll("Zurueckspielen \(name) beginnt")
        let fehler = try DroboKern.zurueckspielenAusfuehren(geraet: m.rohgeraet, sicherung: d, uuid: uuid, schreibgroesse: schreibgroesse, erzwinge: true)
        if !fehler.isEmpty {
            ablage.merkerAendern(uuid) { $0.offenePruefung = "Zurueckspielen nicht sauber: " + fehler.joined(separator: "; ") }
            ablage.protokoll("Zurueckspielen \(name): FEHLER " + fehler.joined(separator: "; "))
            throw AppFehler.sicherung("Nach dem Zurueckschreiben weichen Bereiche ab: " + fehler.joined(separator: "; "))
        }
        let r = try nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse)
        ablage.merkerAendern(uuid) { $0.rwAktiv = false; $0.letztePruefung = r; $0.offenePruefung = r.ok ? nil : "Pruefung nach dem Zurueckspielen nicht bestanden" }
        ablage.protokoll("Zurueckgespielt \(name); Pruefung: " + (r.ok ? "in Ordnung" : "NICHT in Ordnung: " + r.probleme.joined(separator: "; ")))
        return r
    }
}
