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

public enum ErprobtErgebnis: Equatable {
    case erprobt
    /// Erprobte Kombinationen fuer diese Aktion, damit der Nutzer sieht, wofuer es Belege gibt.
    case nichtErprobt(erprobt: [ErprobtEintrag])
}

/// Kabel-iSCSI: nur gelesen, Schreiben NICHT erprobt. USB/FireWire an der DroboPro: nie gemessen.
public let erprobteDrobos: [ErprobtEintrag] = [
    ErprobtEintrag(modell: "5c gen3", anzeige: "Drobo 5C Gen3", firmwareBuild: 50532, anschluss: .usb, schreiben: true, formatieren: false, beleg: "Schreibtest 21/21, Platzsperre, Haertetest Abbilder"),
    ErprobtEintrag(modell: "pro", anzeige: "DroboPro", firmwareBuild: 22137, anschluss: .iscsiWLAN, schreiben: true, formatieren: true, beleg: "200 MiB, md5 nach Neueinhaengen; LUN 1 formatiert und verifiziert"),
    ErprobtEintrag(modell: "pro", anzeige: "DroboPro", firmwareBuild: 22137, anschluss: .iscsiKabel, schreiben: false, formatieren: false, beleg: "nur gelesen"),
]

func normalisiere(_ modell: String) -> String {
    var m = modell.trimmingCharacters(in: .whitespaces).lowercased()
    if m.hasPrefix("drobo") { m = String(m.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    return m
}

/// Modell und Firmware-Build kommen aus Seite 0x08 (DroboStatus). Build unbekannt (nil) = nicht erprobt.
public func erprobt(modell: String, build: Int?, anschluss: Anschluss, aktion: ErprobtAktion) -> ErprobtErgebnis {
    let fuerAktion = erprobteDrobos.filter { aktion == .schreiben ? $0.schreiben : $0.formatieren }
    if let b = build, fuerAktion.contains(where: { $0.modell == normalisiere(modell) && $0.firmwareBuild == b && $0.anschluss == anschluss }) { return .erprobt }
    return .nichtErprobt(erprobt: fuerAktion)
}

// MARK: Anschluss zur Laufzeit

public enum SchnittstellenArt: Equatable { case wlan, kabel, andere }

/// BSD-Name (en0) der IPv4-Schnittstelle, in deren Teilnetz `host` liegt; nil = keine (Route ginge ueber ein Gateway oder Adresse ungueltig).
public func schnittstelleZu(host: String) -> String? {
    var a = in_addr(); guard inet_pton(AF_INET, host, &a) == 1 else { return nil }
    var liste: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&liste) == 0, let start = liste else { return nil }
    defer { freeifaddrs(liste) }
    var p: UnsafeMutablePointer<ifaddrs>? = start
    while let i = p?.pointee {
        defer { p = i.ifa_next }
        guard let ad = i.ifa_addr, let mk = i.ifa_netmask, ad.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        let ip = ad.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let mask = mk.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        if ip & mask == a.s_addr & mask { return String(cString: i.ifa_name) }
    }
    return nil
}

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
