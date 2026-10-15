import Foundation

public let helferDienst = "de.begod.drobohelper"
public let appKennung = "de.begod.drobofsprobe"
public let cliKennung = "de.begod.drobo"
public let teamID = "JR9H9Q532P"
/// Peer muss mit einem Zertifikat desselben Teams signiert sein; Kennung App oder CLI (CLI nur, wenn mit `codesign -i de.begod.drobo` signiert: tools/sign_cli.sh).
public let helferAnforderung = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (identifier \"\(appKennung)\" or identifier \"\(cliKennung)\")"

/// XPC-Schnittstelle des Hilfsdienstes: genau zwei Aufrufe. Antwort nil = ok, sonst Fehlertext.
@objc public protocol DroboHelferProtokoll {
    func freigeben(_ volumeUUID: String, reply: @escaping (String?) -> Void)
    func zurueckgeben(_ volumeUUID: String, reply: @escaping (String?) -> Void)
}

public struct HelferFehler: Error, CustomStringConvertible, Equatable {
    public var description: String
    init(_ s: String) { description = s }
}

/// Die ganze Entscheidungslogik des Dienstes, ohne Root testbar: alles Systemnahe ist austauschbar.
public struct HelferLogik {
    public var finden: (String) -> Medium? = DroboKern.finden(uuid:)
    public var ordnerVon: (uid_t) -> String? = { getpwuid($0).map { String(cString: $0.pointee.pw_dir) } }
    public var knotenArt: (String) -> mode_t? = { var s = stat(); return lstat($0, &s) == 0 ? s.st_mode & S_IFMT : nil }
    public var chown: (String, uid_t, gid_t) -> Int32 = { Darwin.chown($0, $1, $2) }
    public var chmod: (String, mode_t) -> Int32 = { Darwin.chmod($0, $1) }
    public var operatorGID: () -> gid_t? = { getgrnam("operator").map { $0.pointee.gr_gid } }
    public init() {}

    static let uuidMuster = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
    static let partition = #"^disk[0-9]+s[0-9]+$"#

    /// Liste des ANFRAGENDEN Nutzers; kaputt, fehlend oder ohne Eintrag = Ablehnung.
    func pruefen(_ uuid: String, uid: uid_t) throws -> Medium {
        guard uuid.range(of: Self.uuidMuster, options: .regularExpression) != nil else { throw HelferFehler("keine gueltige UUID") }
        guard let home = ordnerVon(uid) else { throw HelferFehler("kein Home fuer uid \(uid)") }
        let pfad = home + "/Library/Containers/\(modulKennung)/Data/freigabe.json"
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

    public func zurueckgeben(_ uuid: String, uid: uid_t) throws {
        let m = try pruefen(uuid, uid: uid)
        guard let g = operatorGID() else { throw HelferFehler("Gruppe operator fehlt") }
        for k in [m.geraet, m.rohgeraet] {
            if chown(k, 0, g) != 0 { throw HelferFehler("chown \(k): \(String(cString: strerror(errno)))") }
            if chmod(k, 0o640) != 0 { throw HelferFehler("chmod \(k): \(String(cString: strerror(errno)))") }
        }
    }
}
