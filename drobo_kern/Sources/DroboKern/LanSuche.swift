import Foundation

/// IQN-Praefix der Drobo (Data Robotics): nur Ziele damit gelten als Drobo, fremde iSCSI-Ziele (NAS u. a.) nicht.
public let droboIQNPraefix = "iqn.2005-06.com.datarobotics:"

/// LAN-Suche nach Drobos im EIGENEN Subnetz: Kandidaten aus den aktiven Schnittstellen, nur private Adressen, hoechstens 1024 je Netz; TCP 3260 mit kurzer Frist,
/// bei offenem Port SendTargets. Laeuft im Hilfsdienst (das Datenschutzrecht "Lokales Netzwerk" trifft die App, nicht den Dienst - gemessen).
public struct LanSuche {
    public var port: UInt16 = 3260
    public var praefix = droboIQNPraefix
    public var verbindungsfrist: TimeInterval = 0.3
    public var parallel = 64
    /// Zeitgrenze fuer die Antwort auf SendTargets: unbekannte Adressen 3 s, BEKANNTE Drobo-Adressen 30 s (eine schlafende DroboPro antwortet beim Aufwachen spaet).
    public var bekanntFrist: TimeInterval = 30
    public var pruefung = ISCSIWeiterleitung()
    public init() {}
    /// Nur Tests: anderer Port, Loopback als Kandidat.
    public init(testPort: UInt16) { port = testPort; pruefung = ISCSIWeiterleitung(testLoopbackErlaubt: true) }

    /// Hosts des Netzes `adresse`/`maske` (beide Host-Reihenfolge) ohne Netz-/Broadcastadresse und ohne die eigene; bei mehr als 1024 Adressen das /22 um die eigene.
    public static func kandidaten(adresse: UInt32, maske: UInt32) -> [String] {
        var m = maske
        if (~m &+ 1) > 1024 || m == 0 { m = 0xFFFF_FC00 }
        let netz = adresse & m, ende = netz | ~m
        guard ende > netz + 1 else { return [] }
        return (netz + 1..<ende).filter { $0 != adresse }.map { "\($0 >> 24 & 255).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)" }
    }

    /// Aktive Schnittstellen (UP, nicht Loopback), IPv4, nur private Adressen.
    public static func lokaleKandidaten() -> [String] {
        var liste: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&liste) == 0, let start = liste else { return [] }
        defer { freeifaddrs(liste) }
        var out: [String] = []; let privat = ISCSIWeiterleitung()
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let i = p {
            defer { p = i.pointee.ifa_next }
            let f = Int32(i.pointee.ifa_flags)
            guard f & IFF_UP != 0, f & IFF_LOOPBACK == 0, let a = i.pointee.ifa_addr, let m = i.pointee.ifa_netmask, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            let adr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let eigen = "\(adr >> 24 & 255).\(adr >> 16 & 255).\(adr >> 8 & 255).\(adr & 255)"
            guard privat.adressePruefen(host: eigen) == nil else { continue }          // nie ein Netz ausserhalb der privaten Bereiche absuchen
            out += kandidaten(adresse: adr, maske: mask)
        }
        return Array(Set(out)).sorted()
    }

    func offen(_ host: String) -> Bool {
        guard let d = try? TCPDraht(host: host, port: port, zeitgrenze: verbindungsfrist) else { return false }
        d.schliessen(); return true
    }

    /// Ist unter `host` ein Ziel mit Drobo-IQN-Praefix? (Discovery-Sitzung, keine LUN-Anmeldung.)
    func istDrobo(_ host: String, frist: TimeInterval = 3) -> Bool {
        guard let s = try? ISCSISitzung(host: host, port: port, zeitgrenze: frist) else { return false }
        defer { s.abmelden() }
        return ((try? s.ziele()) ?? []).contains { $0.name.hasPrefix(praefix) }
    }

    /// Hosts mit Drobo-Ziel. Jeder Kandidat muss die Adresspruefung bestehen; `ausnehmen` wird nicht angesprochen.
    public func suchen(kandidaten: [String], ausnehmen: Set<String> = [], bekannt: Set<String> = []) -> [String] {
        let ziele = kandidaten.filter { !ausnehmen.contains($0) && pruefung.adressePruefen(host: $0) == nil }
        var treffer: [String] = []; let sperre = NSLock()
        let gruppe = DispatchGroup(), ampel = DispatchSemaphore(value: parallel)
        for h in ziele {
            ampel.wait(); gruppe.enter()
            DispatchQueue.global().async {
                defer { ampel.signal(); gruppe.leave() }
                if self.offen(h), self.istDrobo(h, frist: bekannt.contains(h) ? self.bekanntFrist : 3) { sperre.lock(); treffer.append(h); sperre.unlock() }
            }
        }
        gruppe.wait()
        return treffer.sorted()
    }
}
