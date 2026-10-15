import Foundation
import os

// Privilegierter Hilfsdienst: genau zwei XPC-Aufrufe (freigeben/zurueckgeben), Logik in HelferLogik.swift (Kern-Paket, dort getestet).
let log = Logger(subsystem: "de.begod.drobohelper", category: "dienst")

final class Dienst: NSObject, NSXPCListenerDelegate, DroboHelferProtokoll {
    let logik = HelferLogik()
    var uid: uid_t = 0   // pro Verbindung eine Instanz, siehe listener(_:shouldAcceptNewConnection:)

    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Aufrufer-Pruefung: Code-Signatur des Peers (audit token) gegen Anforderung; bei Verstoss bricht XPC die Nachricht ab.
        c.setCodeSigningRequirement(helferAnforderung)
        let d = Dienst(); d.uid = c.effectiveUserIdentifier
        log.notice("verbindung uid=\(d.uid, privacy: .public) pid=\(c.processIdentifier, privacy: .public)")
        c.exportedInterface = NSXPCInterface(with: DroboHelferProtokoll.self)
        c.exportedObject = d
        c.resume()
        return true
    }

    func freigeben(_ u: String, reply: @escaping (String?) -> Void) { lauf("freigeben", u, reply) { try self.logik.freigeben(u, uid: self.uid) } }
    func zurueckgeben(_ u: String, reply: @escaping (String?) -> Void) { lauf("zurueckgeben", u, reply) { try self.logik.zurueckgeben(u, uid: self.uid) } }

    func freigabeLesen(_ u: String, reply: @escaping (String?, String?) -> Void) {
        do { let m = try logik.freigabeLesen(u, uid: uid); log.notice("freigabeLesen uid=\(self.uid, privacy: .public) uuid=\(u, privacy: .public): \(m, privacy: .public)"); reply(m, nil) }
        catch { log.error("freigabeLesen uid=\(self.uid, privacy: .public) uuid=\(u, privacy: .public): ABGELEHNT \("\(error)", privacy: .public)"); reply(nil, "\(error)") }
    }
    func freigabeSetzen(_ u: String, modus: String, maxBytes: UInt64, reply: @escaping (String?) -> Void) {
        lauf("freigabeSetzen(\(modus))", u, reply) { try self.logik.freigabeSetzen(u, modus: modus, maxBytes: maxBytes, uid: self.uid) }
    }

    func lauf(_ name: String, _ u: String, _ reply: (String?) -> Void, _ f: () throws -> Void) {
        do { try f(); log.notice("\(name, privacy: .public) uid=\(self.uid, privacy: .public) uuid=\(u, privacy: .public): ok"); reply(nil) }
        catch { log.error("\(name, privacy: .public) uid=\(self.uid, privacy: .public) uuid=\(u, privacy: .public): ABGELEHNT \("\(error)", privacy: .public)"); reply("\(error)") }
    }
}

let dienst = Dienst()
let listener = NSXPCListener(machServiceName: helferDienst)
listener.delegate = dienst
listener.resume()
RunLoop.main.run()
