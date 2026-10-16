import Foundation

public var helferDienst: String { Identitaet.prefix + ".drobohelper" }
public var appKennung: String { Identitaet.prefix + ".drobofsprobe" }
public var modulKennung: String { appKennung + ".fsmodule" }
public var cliKennung: String { Identitaet.prefix + ".drobo" }
/// Name der launchd-Beschreibung im App-Bundle (Contents/Library/LaunchDaemons).
public var helferPlistName: String { helferDienst + ".plist" }
/// Der Aufrufer muss vom selben Team signiert sein wie der Dienst selbst (Team aus der eigenen Signatur); Kennung App oder CLI (CLI: `codesign -i <Praefix>.drobo`, tools/sign_cli.sh).
public var helferAnforderung: String { anforderung(prefix: Identitaet.prefix, team: Identitaet.eigenesTeam() ?? "") }

/// XPC-Schnittstelle des Hilfsdienstes: genau zwei Aufrufe. Antwort nil = ok, sonst Fehlertext.
@objc public protocol DroboHelferProtokoll {
    func freigeben(_ volumeUUID: String, reply: @escaping (String?) -> Void)
    func zurueckgeben(_ volumeUUID: String, reply: @escaping (String?) -> Void)
    /// Freigabeliste des Aufrufers (der Container ist fuer die Shell durch den App-Daten-Schutz gesperrt). Antwort: (Modus, "" = kein Eintrag; Fehlertext).
    func freigabeLesen(_ volumeUUID: String, reply: @escaping (String?, String?) -> Void)
    /// modus: nurlesen | schreiben | entfernen. maxBytes nur fuer neue Eintraege.
    func freigabeSetzen(_ volumeUUID: String, modus: String, maxBytes: UInt64, reply: @escaping (String?) -> Void)
    /// Legt /Volumes/<Volumename> an (Eigentuemer = Aufrufer) und liefert den Pfad. Nur dieser eine Ordnername unter /Volumes, abgeleitet vom Volumenamen der freigegebenen UUID.
    func ordnerAnlegen(_ volumeUUID: String, reply: @escaping (String?, String?) -> Void)
    /// Entfernt genau diesen Ordner wieder (nur leer, nur Ordner des Aufrufers, nie ein Einhaengepunkt).
    func ordnerEntfernen(_ volumeUUID: String, reply: @escaping (String?) -> Void)
    /// Prueft ohne Wirkung, ob der Dienst die Geraeteknoten dieser UUID aendern duerfte (chown auf den bisherigen Eigentuemer). nil = ja, sonst Fehlertext.
    func zugriffPruefen(_ volumeUUID: String, reply: @escaping (String?) -> Void)
}

public struct HelferFehler: Error, CustomStringConvertible, Equatable {
    public var description: String
    init(_ s: String) { description = s }
}

/// Die ganze Entscheidungslogik des Dienstes, ohne Root testbar: alles Systemnahe ist austauschbar.
public struct HelferLogik {
    public var finden: (String) -> Medium? = { sucheNachUUID($0) }
    public var ordnerVon: (uid_t) -> String? = { getpwuid($0).map { String(cString: $0.pointee.pw_dir) } }
    public var knotenArt: (String) -> mode_t? = { var s = stat(); return lstat($0, &s) == 0 ? s.st_mode & S_IFMT : nil }
    public var chown: (String, uid_t, gid_t) -> Int32 = { Darwin.chown($0, $1, $2) }
    public var chmod: (String, mode_t) -> Int32 = { Darwin.chmod($0, $1) }
    public var operatorGID: () -> gid_t? = { getgrnam("operator").map { $0.pointee.gr_gid } }
    public init() {}
    public var mkdir: (String, mode_t) -> Int32 = { Darwin.mkdir($0, $1) }
    public var rmdir: (String) -> Int32 = { Darwin.rmdir($0) }
    public var lstatDatei: (String) -> stat? = { var s = stat(); return lstat($0, &s) == 0 ? s : nil }
    public var inhalt: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) }
    public var volumesBasis = "/Volumes"

    public var datei: (String) -> (uid_t, gid_t)? = { var s = stat(); return stat($0, &s) == 0 ? (s.st_uid, s.st_gid) : nil }
    public var eigner: (String, uid_t, gid_t) -> Int32 = { Darwin.chown($0, $1, $2) }

    static let uuidMuster = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
    static let partition = #"^disk[0-9]+s[0-9]+$"#

    func listenPfad(_ uuid: String, uid: uid_t) throws -> String {
        guard uuid.range(of: Self.uuidMuster, options: .regularExpression) != nil else { throw HelferFehler("keine gueltige UUID") }
        guard let home = ordnerVon(uid) else { throw HelferFehler("kein Home fuer uid \(uid)") }
        return home + "/Library/Containers/\(appKennung).fsmodule/Data/freigabe.json"
    }

    public func freigabeLesen(_ uuid: String, uid: uid_t) throws -> String {
        let p = try listenPfad(uuid, uid: uid)
        do { return try Freigabe.lesen(uuid: uuid, pfad: p)?.rawValue ?? "" } catch { throw HelferFehler("Freigabeliste unbrauchbar: \(error)") }
    }

    /// Schreibt als root in die Liste des Aufrufers: Container muss existieren (wird nicht angelegt), kaputte Liste nie ueberschrieben, Eigentuemer der Datei bleibt/wird der Nutzer.
    public func freigabeSetzen(_ uuid: String, modus: String, maxBytes: UInt64, uid: uid_t) throws {
        let p = try listenPfad(uuid, uid: uid)
        let dir = (p as NSString).deletingLastPathComponent
        guard knotenArt(dir) == S_IFDIR else { throw HelferFehler("Container \(dir) fehlt (Modul nie gestartet?)") }
        let alt = datei(p)
        do {
            if modus == "entfernen" { try Freigabe.entfernen(uuid: uuid, pfad: p) }
            else {
                guard let m = Modus(rawValue: modus) else { throw HelferFehler("Modus \(modus) unbekannt") }
                try Freigabe.setzen(uuid: uuid, modus: m, maxBytes: maxBytes == 0 ? nil : maxBytes, pfad: p)
            }
        } catch let h as HelferFehler { throw h } catch { throw HelferFehler("Freigabeliste: \(error)") }
        let (u, g) = alt ?? (uid, datei(dir)?.1 ?? 20)
        if datei(p) != nil, eigner(p, u, g) != 0 { throw HelferFehler("chown \(p): \(String(cString: strerror(errno)))") }
    }

    /// Liste des ANFRAGENDEN Nutzers; kaputt, fehlend oder ohne Eintrag = Ablehnung.
    func pruefen(_ uuid: String, uid: uid_t) throws -> Medium {
        let pfad = try listenPfad(uuid, uid: uid)
        do { guard try Freigabe.lesen(uuid: uuid, pfad: pfad) != nil else { throw HelferFehler("UUID nicht in der Freigabeliste") } }
        catch let h as HelferFehler { throw h }
        catch { throw HelferFehler("Freigabeliste unbrauchbar: \(error)") }
        guard let m = finden(uuid) else { throw HelferFehler("kein Volume mit dieser UUID") }
        guard m.bsd.range(of: Self.partition, options: .regularExpression) != nil else { throw HelferFehler("\(m.bsd) ist keine Partition (whole disk abgelehnt)") }
        for k in [m.geraet, m.rohgeraet] where knotenArt(k) != S_IFBLK && knotenArt(k) != S_IFCHR { throw HelferFehler("\(k) ist kein Geraeteknoten") }
        return m
    }

    public func freigeben(_ uuid: String, uid: uid_t) throws {
        let m = try pruefen(uuid, uid: uid)
        guard let g = operatorGID() else { throw HelferFehler("Gruppe operator fehlt") }
        for k in [m.geraet, m.rohgeraet] where chown(k, uid, g) != 0 { throw HelferFehler("chown \(k): \(String(cString: strerror(errno)))") }
    }

    /// Gueltiger Ordnername: ein Pfadbestandteil, nicht versteckt, keine Steuerzeichen.
    static func ordnerNameGueltig(_ n: String) -> Bool {
        !n.isEmpty && n.utf8.count <= 255 && !n.hasPrefix(".") && !n.contains("/") && !n.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    func volumenPfad(_ uuid: String, uid: uid_t) throws -> String {
        let m = try pruefen(uuid, uid: uid)
        guard Self.ordnerNameGueltig(m.name) else { throw HelferFehler("Volumename \(m.name.debugDescription) ist als Ordnername unter /Volumes nicht verwendbar") }
        return volumesBasis + "/" + m.name
    }

    public func ordnerAnlegen(_ uuid: String, uid: uid_t) throws -> String {
        let p = try volumenPfad(uuid, uid: uid)
        if mkdir(p, 0o755) != 0 {
            guard errno == EEXIST, let s = lstatDatei(p), s.st_mode & S_IFMT == S_IFDIR, s.st_uid == uid, let b = lstatDatei(volumesBasis), s.st_dev == b.st_dev, inhalt(p)?.isEmpty == true
            else { throw HelferFehler("\(p) nicht anlegbar oder bereits belegt: \(String(cString: strerror(errno)))") }
            return p
        }
        if chown(p, uid, 20) != 0 { let e = String(cString: strerror(errno)); _ = rmdir(p); throw HelferFehler("chown \(p): \(e)") }
        return p
    }

    public func ordnerEntfernen(_ uuid: String, uid: uid_t) throws {
        let p = try volumenPfad(uuid, uid: uid)
        guard let s = lstatDatei(p) else { return }
        guard s.st_mode & S_IFMT == S_IFDIR, s.st_uid == uid, let b = lstatDatei(volumesBasis), s.st_dev == b.st_dev else { throw HelferFehler("\(p) ist kein eigener Ordner oder ein Einhaengepunkt -- nicht entfernt") }
        if rmdir(p) != 0 { throw HelferFehler("rmdir \(p): \(String(cString: strerror(errno)))") }
    }

    /// Wirkungslose Probe: chown mit dem bisherigen Eigentuemer und der bisherigen Gruppe. Scheitert das (z. B. fehlender Festplattenvollzugriff), scheitert auch freigeben.
    public func zugriffPruefen(_ uuid: String, uid: uid_t) throws {
        let m = try pruefen(uuid, uid: uid)
        for k in [m.geraet, m.rohgeraet] {
            guard let (u, g) = datei(k) else { throw HelferFehler("\(k) nicht lesbar") }
            if eigner(k, u, g) != 0 { throw HelferFehler("chown \(k): \(String(cString: strerror(errno)))") }
        }
    }

    public func zurueckgeben(_ uuid: String, uid: uid_t) throws {
        let m = try pruefen(uuid, uid: uid)
        guard let g = operatorGID() else { throw HelferFehler("Gruppe operator fehlt") }
        for k in [m.geraet, m.rohgeraet] {
            if chown(k, 0, g) != 0 { throw HelferFehler("chown \(k): \(String(cString: strerror(errno)))") }
            if chmod(k, 0o640) != 0 { throw HelferFehler("chmod \(k): \(String(cString: strerror(errno)))") }
        }
    }
}

private func sucheNachUUID(_ u: String) -> Medium? { finden(uuid: u) }
