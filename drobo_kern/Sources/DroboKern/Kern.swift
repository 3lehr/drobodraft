import Foundation

public let vorgabeUUID = "C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1"
public let modulKennung = "de.begod.drobofsprobe.fsmodule"
public let vorgabeOrt = "/private/tmp/drobo_mnt"

public struct ModulStatus: Equatable { public var installiert: Bool; public var freigeschaltet: Bool }

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
    public var freigabePfad: String
    public var modul: () -> ModulStatus
    public var home: [String]
    /// Hilfsdienst (freigeben|zurueckgeben): nil = ok, sonst Fehlertext. Nie fatal: reicht der Zugriff trotzdem, geht es weiter.
    public var helfer: (String, String) -> String? = { helferAufruf($0, uuid: $1) }
    public var meldung: (String) -> Void = { FileHandle.standardError.write(Data("HINWEIS: \($0)\n".utf8)) }

    public static func umgebung(_ k: String) -> String? { ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 } }

    public init(uuid: String = Kern.umgebung("DROBO_UUID") ?? vorgabeUUID,
                freigabePfad: String = Freigabe.standardPfad,
                modul: @escaping () -> ModulStatus = modulStatus,
                home: [String] = [NSHomeDirectory(), ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()]) {
        self.uuid = uuid.uppercased(); self.freigabePfad = freigabePfad; self.modul = modul; self.home = home
    }

    public func zustand() throws -> Zustand {
        let fr = try Freigabe.lesen(uuid: uuid, pfad: freigabePfad)
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
        try Freigabe.setzen(uuid: uuid, modus: modus, maxBytes: mb, pfad: freigabePfad)
    }

    /// Ort liegt unter Home? Aufgeloest ueber Symlinks (der naechste vorhandene Vorfahr), damit /var/.. oder Links nicht taeuschen.
    static func aufgeloest(_ pfad: String) -> String {
        var url = URL(fileURLWithPath: pfad).standardizedFileURL; var rest: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { rest.insert(url.lastPathComponent, at: 0); url.deleteLastPathComponent() }
        return rest.reduce(url.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    func unterHome(_ ort: String) -> Bool {
        let o = Kern.aufgeloest(ort)
        return home.contains { let h = Kern.aufgeloest($0); return o == h || o.hasPrefix(h + "/") }
    }

    @discardableResult
    public func einhaengen(modus: Modus = .nurlesen, ort: String = vorgabeOrt) throws -> Einhaengung {
        if unterHome(ort) { throw Fehler.ortUnterHome(ort) }
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        if let e = einhaengungen()[m.geraet] { throw Fehler.eingehaengt("\(m.geraet) auf \(e.ort) (\(e.nurlesen ? "ro" : "rw"))") }
        guard let f = try Freigabe.lesen(uuid: uuid, pfad: freigabePfad) else { throw Fehler.keineFreigabe(uuid) }
        if modus == .schreiben && f != .schreiben {
            throw Fehler.freigabeReichtNicht("Freigabe fuer \(uuid) steht auf nurlesen, Schreiben verlangt. Aendern: drobo freigabe schreiben")
        }
        let mod = modul()
        if !mod.installiert { throw Fehler.modul("Modul \(modulKennung) nicht installiert (tools/install_module.sh)") }
        if !mod.freigeschaltet { throw Fehler.modul("Modul \(modulKennung) nicht freigeschaltet (Systemeinstellungen, Betreiber)") }
        if let h = helfer("freigeben", uuid) { meldung("Hilfsdienst: \(h)") }
        let t = try torpruefung(pfad: m.rohgeraet)
        if !t.ok { throw Fehler.tor(t.probleme) }
        try FileManager.default.createDirectory(atPath: ort, withIntermediateDirectories: true)
        let (rc, out) = ausfuehren("/sbin/mount", ["-F", "-t", "hfsdrobo", "-o", modus == .nurlesen ? "rdonly" : "rw", m.geraet, ort])
        guard rc == 0 else { throw Fehler.mountFehlgeschlagen(out.isEmpty ? "Exit \(rc)" : out) }
        guard let e = einhaengungen()[m.geraet] else { throw Fehler.mountFehlgeschlagen("mount meldete Erfolg, Mount-Tabelle zeigt \(m.geraet) nicht") }
        if modus == .nurlesen && !e.nurlesen {
            _ = ausfuehren("/sbin/umount", [ort])
            throw Fehler.mountFehlgeschlagen("Mount ist NICHT read-only gemeldet -> ausgehaengt")
        }
        return e
    }

    public func aushaengen() throws {
        guard let m = finden(uuid: uuid) else { throw Fehler.nichtGefunden(uuid) }
        guard let e = einhaengungen()[m.geraet] else { throw Fehler.nichtEingehaengt(uuid) }
        var (rc, out) = ausfuehren("/sbin/umount", [e.ort])
        if rc != 0 { (rc, out) = ausfuehren("/usr/sbin/diskutil", ["unmount", e.ort]) }
        if rc != 0 || einhaengungen()[m.geraet] != nil { throw Fehler.aushaengenFehlgeschlagen(out) }
        if let h = helfer("zurueckgeben", uuid) { meldung("Hilfsdienst: \(h). Knoten bleibt beim Nutzer; zurueck: sudo chown root:operator \(m.geraet) \(m.rohgeraet)") }
    }
}
