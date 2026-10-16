import Foundation

public enum Rolle: String, Codable, Equatable { case arbeitsvolume, timemachine }

/// Eine bekannte Drobo. Rolle timemachine = nur anzeigen, nie ueber unser Modul einhaengen.
public struct DroboEintrag: Codable, Equatable {
    public var uuid: String
    public var name: String
    public var rolle: Rolle
    public init(uuid: String, name: String, rolle: Rolle = .arbeitsvolume) { self.uuid = uuid.uppercased(); self.name = name; self.rolle = rolle }
}

public let vorgabeSicherungOrt = "/Volumes/daten/DroboSicherungen"

public struct Einstellungen: Codable, Equatable {
    public var drobos: [DroboEintrag] = [DroboEintrag(uuid: vorgabeUUID, name: "Drobo 5C")]
    public var einhaengeort = vorgabeOrt
    public var vorgabeSchreiben = false
    public var sicherungOrt = vorgabeSicherungOrt
    public var sicherungAnzahl = 2
    public var mitteilungen = true
    /// Spotlight/Time-Machine-Ausschluss: nur Einstellung des Betreibers, Vorgabe aus (Hinweis statt Zwang).
    public var spotlightAusgeschlossen = false
    public init() {}
    enum CodingKeys: String, CodingKey { case drobos, einhaengeort, vorgabeSchreiben, sicherungOrt, sicherungAnzahl, mitteilungen, spotlightAusgeschlossen }
    public init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        drobos = try c.decodeIfPresent([DroboEintrag].self, forKey: .drobos) ?? drobos
        einhaengeort = try c.decodeIfPresent(String.self, forKey: .einhaengeort) ?? einhaengeort
        vorgabeSchreiben = try c.decodeIfPresent(Bool.self, forKey: .vorgabeSchreiben) ?? vorgabeSchreiben
        sicherungOrt = try c.decodeIfPresent(String.self, forKey: .sicherungOrt) ?? sicherungOrt
        sicherungAnzahl = try c.decodeIfPresent(Int.self, forKey: .sicherungAnzahl) ?? sicherungAnzahl
        mitteilungen = try c.decodeIfPresent(Bool.self, forKey: .mitteilungen) ?? mitteilungen
        spotlightAusgeschlossen = try c.decodeIfPresent(Bool.self, forKey: .spotlightAusgeschlossen) ?? spotlightAusgeschlossen
    }
}

public struct PruefErgebnis: Codable, Equatable {
    public enum Tiefe: String, Codable { case ok, fehler, nichtVerfuegbar }
    public var zeit = ""
    public var ok = false
    public var probleme: [String] = []
    public var hinweise: [String] = []
    public var tiefe: Tiefe = .nichtVerfuegbar
    public init() {}
}

/// Dauerhafter Zustand je Volume: ueberlebt Neustart der App (sicheres Abziehen).
public struct Merker: Codable, Equatable {
    public var rwAktiv = false
    public var bsd = ""
    public var ort = ""
    public var seit = ""
    /// Gesetzt, solange vor dem naechsten Einhaengen geprueft werden muss (Trennung im Schreibzustand, fehlgeschlagene Pruefung); Text = Grund.
    public var offenePruefung: String?
    public var letztePruefung: PruefErgebnis?
    public var letzteSicherung: String?
    public init() {}
}

public struct TempoMessung: Codable, Equatable {
    public var zeit: String
    public var art: String          // lesen | schreiben
    public var mbProSekunde: Double
    public var bytes: UInt64
    public var dateien: Int
    public var uuid: String
}

public func jetztText(_ d: Date = Date()) -> String {
    let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
    return f.string(from: d)
}

/// Einstellungen, Zustand, Protokoll und Tempo-Verlauf unter einem Ordner (Vorgabe ~/Library/Application Support/Drobo, Umgebung DROBO_DATEN).
public final class Datenablage {
    public let ordner: String
    static let sperre = NSLock()
    public init(ordner: String? = Kern.umgebung("DROBO_DATEN")) {
        self.ordner = ordner ?? NSHomeDirectory() + "/Library/Application Support/Drobo"
    }
    func pfad(_ n: String) -> String { ordner + "/" + n }

    func lesen<T: Decodable>(_ n: String, _ t: T.Type) -> T? {
        FileManager.default.contents(atPath: pfad(n)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    func schreiben<T: Encodable>(_ n: String, _ w: T) {
        try? FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(w) { try? d.write(to: URL(fileURLWithPath: pfad(n)), options: .atomic) }
    }

    public func einstellungen() -> Einstellungen { Self.sperre.lock(); defer { Self.sperre.unlock() }; return lesen("einstellungen.json", Einstellungen.self) ?? Einstellungen() }
    public func einstellungenSetzen(_ e: Einstellungen) { Self.sperre.lock(); defer { Self.sperre.unlock() }; schreiben("einstellungen.json", e) }

    public func merker(_ uuid: String) -> Merker {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        return (lesen("zustand.json", [String: Merker].self) ?? [:])[uuid.uppercased()] ?? Merker()
    }
    @discardableResult
    public func merkerAendern(_ uuid: String, _ f: (inout Merker) -> Void) -> Merker {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        var alle = lesen("zustand.json", [String: Merker].self) ?? [:]
        var m = alle[uuid.uppercased()] ?? Merker(); f(&m); alle[uuid.uppercased()] = m
        schreiben("zustand.json", alle); return m
    }

    public struct Eintrag: Codable, Equatable { public var zeit: String; public var text: String }
    public func protokoll(_ text: String) {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        try? FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(Eintrag(zeit: jetztText(), text: text)) else { return }
        let p = pfad("protokoll.jsonl")
        if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close() }
    }
    public func protokollLesen(letzte: Int = 200) -> [Eintrag] {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        let t = FileManager.default.contents(atPath: pfad("protokoll.jsonl")).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return t.split(separator: "\n").suffix(letzte).compactMap { try? JSONDecoder().decode(Eintrag.self, from: Data($0.utf8)) }
    }

    public func tempoVerlauf() -> [TempoMessung] {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        return lesen("tempo.json", [TempoMessung].self) ?? []
    }
    public func tempoAnhaengen(_ m: TempoMessung) {
        Self.sperre.lock(); defer { Self.sperre.unlock() }
        var l = lesen("tempo.json", [TempoMessung].self) ?? []; l.append(m)
        schreiben("tempo.json", Array(l.suffix(200)))
    }
}
