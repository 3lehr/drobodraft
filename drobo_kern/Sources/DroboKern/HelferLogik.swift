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
    /// Sucht im eigenen IPv4-Subnetz (nur private Bereiche) nach Drobos mit iSCSI-Ziel (IQN-Praefix Data Robotics). `ausnehmen`: Adressen, an denen nicht angeklopft wird
    /// (eingehaengte DroboPro bedient nur eine Sitzung). `bekannte`: Adressen eingerichteter Drobos, deren SendTargets-Antwort bis 30 s abgewartet wird (Aufwachen). Antwort: Adressen.
    func iscsiSuche(ausnehmen: [String], bekannte: [String], reply: @escaping ([String]) -> Void)
    /// Lokaler Loopback-Port, der zu host:port (nur IPv4 im privaten Netz, nur Port 3260) weiterleitet. Grund: das Modul hfsdropro bekommt wegen des Datenschutzes
    /// "Lokales Netzwerk" kein Routing ins LAN, der Dienst nicht (gemessen, Plan DroboPro). Antwort (Port, Fehlertext); Port 0 = Fehler.
    func iscsiWeiterleitung(_ host: String, port: UInt16, reply: @escaping (UInt16, String?) -> Void)
    /// Wie freigabeSetzen, aber fuer den Container des iSCSI-Moduls (<Praefix>.drobofsprobe.iscsi). maxBytes ist Pflicht (Gate).
    func iscsiFreigabeSetzen(_ volumeUUID: String, modus: String, maxBytes: UInt64, reply: @escaping (String?) -> Void)
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

    func listenPfad(_ uuid: String, uid: uid_t, modul: String = ".fsmodule") throws -> String {
        guard uuid.range(of: Self.uuidMuster, options: .regularExpression) != nil else { throw HelferFehler("keine gueltige UUID") }
        guard let home = ordnerVon(uid) else { throw HelferFehler("kein Home fuer uid \(uid)") }
        return home + "/Library/Containers/\(appKennung)\(modul)/Data/freigabe.json"
    }

    public func freigabeLesen(_ uuid: String, uid: uid_t) throws -> String {
        let p = try listenPfad(uuid, uid: uid)
        do { return try Freigabe.lesen(uuid: uuid, pfad: p)?.rawValue ?? "" } catch { throw HelferFehler("Freigabeliste unbrauchbar: \(error)") }
    }

    /// Schreibt als root in die Liste des Aufrufers: Container muss existieren (wird nicht angelegt), kaputte Liste nie ueberschrieben, Eigentuemer der Datei bleibt/wird der Nutzer.
    public func freigabeSetzen(_ uuid: String, modus: String, maxBytes: UInt64, uid: uid_t, modul: String = ".fsmodule") throws {
        if modul == ".iscsi" && modus != "entfernen" && maxBytes == 0 { throw HelferFehler("iSCSI-Freigabe braucht max_bytes") }
        let p = try listenPfad(uuid, uid: uid, modul: modul)
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

/// Weiterleitung 127.0.0.1:<System-Port> -> host:3260 fuer das iSCSI-Modul (siehe Protokoll `iscsiWeiterleitung`). Reine Byte-Pumpe, keine iSCSI-Kenntnis.
/// Grenzen: Ziel nur IPv4-Literal in 10/8, 172.16/12, 192.168/16, 169.254/16, Port nur 3260; Listener nur Loopback; eine Weiterleitung je Ziel, wiederverwendet.
/// Jeder lokale Prozess kann den Loopback-Port nutzen: gleichwertig zum direkten LAN-Zugang, keine neue Reichweite.
/// ponytail: ein Thread je Verbindung (wenige Verbindungen: eine iSCSI-Sitzung je Mount); Weiterleitungen leben bis Dienstende (Leerlauf-Ende wartet auf `offen == 0`).
public final class ISCSIWeiterleitung {
    public static let zielPort: UInt16 = 3260
    private let lock = NSLock()
    private var listener: [String: UInt16] = [:]       // "host:port" -> lokaler Port
    private var _offen = 0
    private var sockets = Set<Int32>()                 // offene Weiterleitungs-Sockets (Client und Ziel), fuer geordnetes Schliessen bei SIGTERM
    private let loopbackErlaubt: Bool
    /// Zahl gerade weitergeleiteter Verbindungen (Leerlauf-Ende des Dienstes wartet auf 0).
    public var offen: Int { lock.lock(); defer { lock.unlock() }; return _offen }

    /// Leerlauf-Ende des Dienstes: keine XPC-Verbindung, keine weitergeleitete Verbindung, seit `letzte` mehr als 30 s Ruhe.
    public func beendenErlaubt(aktiv: Int, letzte: Date, jetzt: Date = Date()) -> Bool { aktiv <= 0 && offen == 0 && jetzt.timeIntervalSince(letzte) > 30 }

    /// SIGTERM des Dienstes: alle Weiterleitungen geordnet schliessen (shutdown beider Seiten, die Pump-Threads beenden sich und schliessen), dann bis `warte` s auf offen == 0.
    /// Die Pumpe kennt kein iSCSI und sendet keinen Logout; die Clients melden sich selbst ab (Kern, Modul), das Ziel sieht hier einen sauberen TCP-Abbau statt eines Abbruchs.
    @discardableResult public func schliesseAlle(warte: TimeInterval = 2) -> Int {
        lock.lock(); let alle = sockets; lock.unlock()
        for fd in alle { shutdown(fd, SHUT_RDWR) }
        let ende = Date().addingTimeInterval(warte)
        while offen > 0 && Date() < ende { Thread.sleep(forTimeInterval: 0.02) }
        return alle.count
    }

    public init() { loopbackErlaubt = false }
    /// Nur Tests: 127.0.0.1 als Ziel zulassen (Python-Pruefziel). Der Dienst nutzt `init()`.
    public init(testLoopbackErlaubt: Bool) { loopbackErlaubt = testLoopbackErlaubt }

    /// nil = erlaubt, sonst Ablehnungsgrund.
    public func zielPruefen(host: String, port: UInt16) -> String? {
        guard port == Self.zielPort else { return "port \(port) not allowed (only \(Self.zielPort))" }
        return adressePruefen(host: host)
    }

    /// Nur die Adresse (private IPv4 in kanonischer Schreibweise); die LAN-Suche prueft damit jeden Kandidaten.
    public func adressePruefen(host: String) -> String? {
        var a = in_addr()
        guard inet_pton(AF_INET, host, &a) == 1 else { return "not an IPv4 literal" }
        let o = withUnsafeBytes(of: a.s_addr) { Array($0) }                       // Netzwerkreihenfolge
        guard o.map(String.init).joined(separator: ".") == host else { return "IPv4 literal not in canonical form" }
        let ok = o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254) || (loopbackErlaubt && o == [127, 0, 0, 1])
        return ok ? nil : "address \(host) is not in a private range"
    }

    /// Lokaler Port fuer host:port; startet beim ersten Aufruf den Listener, danach wiederverwendet.
    public func port(host: String, port: UInt16) throws -> UInt16 {
        if let grund = zielPruefen(host: host, port: port) { throw HelferFehler(grund) }
        lock.lock(); defer { lock.unlock() }
        let key = "\(host):\(port)"
        if let p = listener[key] { return p }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelferFehler("socket: \(String(cString: strerror(errno)))") }
        var an: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &an, socklen_t(MemoryLayout<Int32>.size))
        var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET); sa.sin_port = 0
        sa.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let r = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let g = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard r == 0, g == 0, listen(fd, 8) == 0 else { let e = String(cString: strerror(errno)); close(fd); throw HelferFehler("listener: \(e)") }
        let lokal = UInt16(bigEndian: sa.sin_port)
        listener[key] = lokal
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                Thread.detachNewThread { self.leite(c, host: host, port: port) }
            }
        }
        return lokal
    }

    private func leite(_ client: Int32, host: String, port: UInt16) {
        lock.lock(); _offen += 1; sockets.insert(client); lock.unlock()
        defer { lock.lock(); _offen -= 1; sockets.remove(client); lock.unlock() }
        defer { close(client) }
        let ziel = socket(AF_INET, SOCK_STREAM, 0)
        guard ziel >= 0 else { return }
        defer { close(ziel) }
        lock.lock(); sockets.insert(ziel); lock.unlock()
        defer { lock.lock(); sockets.remove(ziel); lock.unlock() }      // vor close(ziel): shutdown trifft nie einen wiederverwendeten Deskriptor
        var sa = sockaddr_in(); sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sa.sin_family = sa_family_t(AF_INET); sa.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &sa.sin_addr)
        let c = withUnsafePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(ziel, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard c == 0 else { return }
        var an: Int32 = 1
        for f in [client, ziel] { setsockopt(f, IPPROTO_TCP, TCP_NODELAY, &an, socklen_t(MemoryLayout<Int32>.size)); setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &an, socklen_t(MemoryLayout<Int32>.size)) }
        var puffer = [UInt8](repeating: 0, count: 1 << 17)
        var p = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: ziel, events: Int16(POLLIN), revents: 0)]
        while poll(&p, 2, -1) >= 0 || errno == EINTR {
            for i in 0..<2 where p[i].revents != 0 {
                let (von, nach) = i == 0 ? (client, ziel) : (ziel, client)
                let n = recv(von, &puffer, puffer.count, 0)
                if n <= 0 { return }                                      // eine Seite schliesst (oder Fehler): beide zu
                var off = 0
                while off < n { let w = puffer[off..<n].withUnsafeBytes { send(nach, $0.baseAddress, $0.count, 0) }; if w <= 0 { return }; off += w }
            }
        }
    }
}
