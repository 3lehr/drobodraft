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
