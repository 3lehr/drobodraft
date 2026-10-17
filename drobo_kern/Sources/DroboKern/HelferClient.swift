import Foundation

/// Ein XPC-Aufruf an den Hilfsdienst. `aufruf` bekommt den Proxy und die Antwortklappe; Rueckgabe: Antwortwerte oder Fehlertext
/// (Verbindung scheitert binnen Sekunden, wenn der Dienst nicht freigeschaltet ist).
func helferRPC(frist: TimeInterval = 5, _ aufruf: (DroboHelferProtokoll, @escaping ([String?]) -> Void) -> Void) -> (antwort: [String?], fehler: String?) {
    let c = NSXPCConnection(machServiceName: helferDienst, options: .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: DroboHelferProtokoll.self)
    c.resume(); defer { c.invalidate() }
    let sem = DispatchSemaphore(value: 0)
    var a: [String?] = []; var f: String? = "keine Antwort vom Hilfsdienst"
    let p = c.remoteObjectProxyWithErrorHandler { f = "Hilfsdienst nicht erreichbar (nicht freigeschaltet?): \($0.localizedDescription)"; sem.signal() } as! DroboHelferProtokoll
    aufruf(p) { a = $0; f = nil; sem.signal() }
    if sem.wait(timeout: .now() + frist) == .timedOut { return ([], "Hilfsdienst antwortet nicht in \(Int(frist)) s") }
    return (a, f)
}

/// nil = ok, sonst Fehlertext.
public func helferAufruf(_ name: String, uuid: String, frist: TimeInterval = 5) -> String? {
    let r = helferRPC(frist: frist) { p, k in
        if name == "freigeben" { p.freigeben(uuid, reply: { k([$0]) }) } else { p.zurueckgeben(uuid, reply: { k([$0]) }) }
    }
    return r.fehler ?? r.antwort.first ?? nil
}

public func helferFreigabeLesen(uuid: String) throws -> Modus? {
    let r = helferRPC { p, k in p.freigabeLesen(uuid, reply: { k([$0, $1]) }) }
    if let f = r.fehler ?? (r.antwort.count > 1 ? r.antwort[1] : nil) { throw Fehler.helfer(f) }
    let m = r.antwort.first.flatMap { $0 } ?? ""
    return m.isEmpty ? nil : Modus(rawValue: m)
}

public func helferFreigabeSetzen(uuid: String, modus: String, maxBytes: UInt64) throws {
    let r = helferRPC { p, k in p.freigabeSetzen(uuid, modus: modus, maxBytes: maxBytes, reply: { k([$0]) }) }
    if let f = r.fehler ?? r.antwort.first ?? nil { throw Fehler.helfer(f) }
}

/// Legt den Einhaengeordner /Volumes/<Volumename> ueber den Hilfsdienst an; Rueckgabe Pfad.
public func helferOrdnerAnlegen(uuid: String) throws -> String {
    let r = helferRPC { p, k in p.ordnerAnlegen(uuid, reply: { k([$0, $1]) }) }
    if let f = r.fehler ?? (r.antwort.count > 1 ? r.antwort[1] : nil) { throw Fehler.helfer(f) }
    guard let p = r.antwort.first ?? nil else { throw Fehler.helfer("keine Antwort") }
    return p
}

/// nil = ok, sonst Fehlertext.
public func helferOrdnerEntfernen(uuid: String) -> String? {
    let r = helferRPC { p, k in p.ordnerEntfernen(uuid, reply: { k([$0]) }) }
    return r.fehler ?? r.antwort.first ?? nil
}

/// iSCSI-Einhaengepunkt /Volumes/<name> ueber den Dienst (bei Belegung "<name> 2" ...); Rueckgabe Pfad.
public func helferISCSIOrdnerAnlegen(uuid: String, name: String) throws -> String {
    let r = helferRPC { p, k in p.iscsiOrdnerAnlegen(uuid, name: name, reply: { k([$0, $1]) }) }
    if let f = r.fehler ?? (r.antwort.count > 1 ? r.antwort[1] : nil) { throw Fehler.helfer(f) }
    guard let p = r.antwort.first ?? nil else { throw Fehler.helfer("keine Antwort") }
    return p
}

/// nil = ok, sonst Fehlertext.
public func helferISCSIOrdnerEntfernen(pfad: String) -> String? {
    let r = helferRPC { p, k in p.iscsiOrdnerEntfernen(pfad, reply: { k([$0]) }) }
    return r.fehler ?? r.antwort.first ?? nil
}

/// nil = der Dienst darf zugreifen (wirkungslose Probe), sonst Fehlertext.
public func helferZugriffPruefen(uuid: String) -> String? {
    let r = helferRPC { p, k in p.zugriffPruefen(uuid, reply: { k([$0]) }) }
    return r.fehler ?? r.antwort.first ?? nil
}

/// Lokaler Weiterleitungsport des Dienstes zu host:3260 (siehe DroboHelferProtokoll.iscsiWeiterleitung).
public func helferISCSIWeiterleitung(host: String) throws -> UInt16 {
    var port: UInt16 = 0
    let r = helferRPC { p, k in p.iscsiWeiterleitung(host, port: 3260, reply: { port = $0; k([$1]) }) }
    if let f = r.fehler ?? r.antwort.first ?? nil { throw Fehler.helfer(f) }
    guard port != 0 else { throw Fehler.helfer("kein Port") }
    return port
}

/// Freigabe im Container des iSCSI-Moduls setzen (modus nurlesen | schreiben | entfernen).
public func helferISCSIFreigabeSetzen(uuid: String, modus: String, maxBytes: UInt64) throws {
    let r = helferRPC { p, k in p.iscsiFreigabeSetzen(uuid, modus: modus, maxBytes: maxBytes, reply: { k([$0]) }) }
    if let f = r.fehler ?? r.antwort.first ?? nil { throw Fehler.helfer(f) }
}

/// LAN-Suche im Hilfsdienst (siehe LanSuche): Adressen mit Drobo-Ziel im eigenen Subnetz.
public func helferISCSISuche(ausnehmen: Set<String>, bekannte: Set<String> = []) throws -> [String] {
    var hosts: [String] = []
    let r = helferRPC(frist: 60) { p, k in p.iscsiSuche(ausnehmen: Array(ausnehmen), bekannte: Array(bekannte), reply: { hosts = $0; k([nil]) }) }
    if let f = r.fehler { throw Fehler.helfer(f) }
    return hosts
}
