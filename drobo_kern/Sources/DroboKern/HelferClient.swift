import Foundation

/// Ruft den Hilfsdienst; nil = ok, sonst Fehlertext. Ohne freigeschalteten Dienst scheitert die Verbindung binnen Sekunden.
public func helferAufruf(_ name: String, uuid: String, frist: TimeInterval = 5) -> String? {
    let c = NSXPCConnection(machServiceName: helferDienst, options: .privileged)
    c.remoteObjectInterface = NSXPCInterface(with: DroboHelferProtokoll.self)
    c.resume(); defer { c.invalidate() }
    let sem = DispatchSemaphore(value: 0)
    var antwort: String? = "keine Antwort vom Hilfsdienst"
    let p = c.remoteObjectProxyWithErrorHandler { antwort = "Hilfsdienst nicht erreichbar (nicht freigeschaltet?): \($0.localizedDescription)"; sem.signal() } as! DroboHelferProtokoll
    let fertig: (String?) -> Void = { antwort = $0; sem.signal() }
    if name == "freigeben" { p.freigeben(uuid, reply: fertig) } else { p.zurueckgeben(uuid, reply: fertig) }
    if sem.wait(timeout: .now() + frist) == .timedOut { return "Hilfsdienst antwortet nicht in \(Int(frist)) s" }
    return antwort
}
