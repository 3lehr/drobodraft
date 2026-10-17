import Foundation
import SystemConfiguration

/// Mit welchen Drobo-Modellen, Firmware-Staenden UND Anschlussarten wurde eine Aktion bisher gemessen (nur das ist "erprobt").
/// Alles andere wird dem Nutzer vor der Bestaetigung als nicht erprobt gezeigt.
public enum Anschluss: String, Equatable {
    case usb, iscsiWLAN, iscsiKabel, firewire
    /// Netzwerk-Drobo, aber Schnittstelle der Route nicht bestimmbar (z. B. Adapter ohne Typ): nie erprobt.
    case iscsiUnbekannt
}

public struct ErprobtEintrag: Equatable {
    public let modell: String          // wie DroboStatus.modell nach normalisiere(): "5c gen3", "pro"
    public let anzeige: String         // Name fuer die Oberflaeche
    public let firmwareBuild: Int
    public let anschluss: Anschluss
    public let schreiben: Bool
    public let formatieren: Bool
    public let beleg: String
}

public enum ErprobtAktion { case schreiben, formatieren }

/// Was an der Drobo des Nutzers mit einer erprobten Kombination uebereinstimmt, je Merkmal.
public enum Merkmal: String, CaseIterable { case modell, firmware, anschluss }

public enum ErprobtErgebnis: Equatable {
    /// Alle drei Merkmale stimmen mit diesem Eintrag ueberein.
    case erprobt(ErprobtEintrag)
    /// `naechster`: die erprobte Kombination mit den meisten Treffern (Gleichstand: zuerst Modell), `uebereinstimmend`/`abweichend` gelten gegen sie.
    /// `erprobt`: alle erprobten Kombinationen fuer diese Aktion, damit der Nutzer sieht, wofuer es Belege gibt.
    case nichtErprobt(erprobt: [ErprobtEintrag], naechster: ErprobtEintrag?, uebereinstimmend: Set<Merkmal>, abweichend: Set<Merkmal>)

    public var istErprobt: Bool { if case .erprobt = self { return true }; return false }
}

/// Kabel-iSCSI: Schreiben erprobt 2026-10-17 (en8, 100 MBit: iscsi-write-test 4K/256K/512K byte-gleich; Modul 50 MiB, md5 nach Neueinhaengen gleich). Formatieren ueber Kabel nicht. USB/FireWire an der DroboPro: nie gemessen.
public let erprobteDrobos: [ErprobtEintrag] = [
    ErprobtEintrag(modell: "5c gen3", anzeige: "Drobo 5C Gen3", firmwareBuild: 50532, anschluss: .usb, schreiben: true, formatieren: false, beleg: "Schreibtest 21/21, Platzsperre, Haertetest Abbilder"),
    ErprobtEintrag(modell: "pro", anzeige: "DroboPro", firmwareBuild: 22137, anschluss: .iscsiWLAN, schreiben: true, formatieren: true, beleg: "200 MiB, md5 nach Neueinhaengen; LUN 1 formatiert und verifiziert"),
    ErprobtEintrag(modell: "pro", anzeige: "DroboPro", firmwareBuild: 22137, anschluss: .iscsiKabel, schreiben: true, formatieren: false, beleg: "50 MiB über das Modul, Prüfsumme nach Neueinhängen gleich"),
]

func normalisiere(_ modell: String) -> String {
    var m = modell.trimmingCharacters(in: .whitespaces).lowercased()
    if m.hasPrefix("drobo") { m = String(m.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    return m
}

/// Modell und Firmware-Build kommen aus Seite 0x08 (DroboStatus). Build unbekannt (nil) = Firmware weicht ab (nie "erprobt").
public func erprobt(modell: String, build: Int?, anschluss: Anschluss, aktion: ErprobtAktion) -> ErprobtErgebnis {
    let fuerAktion = erprobteDrobos.filter { aktion == .schreiben ? $0.schreiben : $0.formatieren }
    func treffer(_ e: ErprobtEintrag) -> Set<Merkmal> {
        var s = Set<Merkmal>()
        if e.modell == normalisiere(modell) { s.insert(.modell) }
        if let b = build, e.firmwareBuild == b { s.insert(.firmware) }
        if e.anschluss == anschluss { s.insert(.anschluss) }
        return s
    }
    if let e = fuerAktion.first(where: { treffer($0).count == Merkmal.allCases.count }) { return .erprobt(e) }
    let best = fuerAktion.max { (treffer($0).count, treffer($0).contains(.modell) ? 1 : 0) < (treffer($1).count, treffer($1).contains(.modell) ? 1 : 0) }
    let ok = best.map(treffer) ?? []
    return .nichtErprobt(erprobt: fuerAktion, naechster: best, uebereinstimmend: ok, abweichend: Set(Merkmal.allCases).subtracting(ok))
}

// MARK: Anschluss zur Laufzeit

public enum SchnittstellenArt: Equatable { case wlan, kabel, andere }

/// BSD-Name (en8) der Schnittstelle, ueber die die ROUTE zu `host` laeuft (nicht die erste mit passendem Teilnetz: Kabel und WLAN koennen im selben Teilnetz liegen, die Route
/// waehlt eine). Ermittlung ohne Paket: UDP-Socket zu host:3260 `connect`en (Routenwahl im Kernel), Quelladresse per getsockname, Quelladresse -> Schnittstelle (getifaddrs).
/// Loopback liefert lo0 (nie WLAN/Kabel). nil = unbekannt (ungueltige Adresse, keine Route).
public func schnittstelleZu(host: String) -> String? {
    var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(3260).bigEndian
    guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return nil }
    let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return nil }
    defer { close(fd) }
    let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { return nil }
    var q = sockaddr_in(), n = socklen_t(MemoryLayout<sockaddr_in>.size)
    let gs = withUnsafeMutablePointer(to: &q) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &n) } }
    guard gs == 0 else { return nil }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); guard inet_ntop(AF_INET, &q.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
    return schnittstelleFuerQuelle(String(cString: buf), lokaleAdressen())
}

/// (Schnittstelle, IPv4-Adresse) aller Schnittstellen.
func lokaleAdressen() -> [(String, String)] {
    var liste: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&liste) == 0, let start = liste else { return [] }
    defer { freeifaddrs(liste) }
    var out: [(String, String)] = []; var p: UnsafeMutablePointer<ifaddrs>? = start
    while let i = p?.pointee {
        defer { p = i.ifa_next }
        guard let ad = i.ifa_addr, ad.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var sin = ad.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        out.append((String(cString: i.ifa_name), String(cString: buf)))
    }
    return out
}

/// Name der Schnittstelle, die `quelle` (IPv4-Text) traegt; nil = keine.
public func schnittstelleFuerQuelle(_ quelle: String, _ liste: [(String, String)]) -> String? { liste.first { $0.1 == quelle }?.0 }

/// WLAN oder Kabel laut SystemConfiguration (Typ der Schnittstelle); alles andere (Loopback, VPN, Bruecke) = andere.
public func schnittstellenArt(bsd: String) -> SchnittstellenArt {
    for s in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] where SCNetworkInterfaceGetBSDName(s) as String? == bsd {
        let t = SCNetworkInterfaceGetInterfaceType(s) as String?
        if t == kSCNetworkInterfaceTypeIEEE80211 as String { return .wlan }
        if t == kSCNetworkInterfaceTypeEthernet as String { return .kabel }
    }
    return .andere
}

/// Anschluss einer Netzwerk-Drobo (iSCSI). Ermittler injizierbar fuer den Test.
public func anschlussNetz(host: String, schnittstelle: (String) -> String? = schnittstelleZu(host:), art: (String) -> SchnittstellenArt = schnittstellenArt(bsd:)) -> Anschluss {
    guard let n = schnittstelle(host) else { return .iscsiUnbekannt }
    switch art(n) { case .wlan: return .iscsiWLAN; case .kabel: return .iscsiKabel; case .andere: return .iscsiUnbekannt }
}
