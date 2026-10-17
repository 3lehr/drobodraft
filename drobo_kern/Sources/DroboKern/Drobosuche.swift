import Foundation

public struct LanDrobo: Equatable { public var host: String; public var luns: [NetzLun]
    public init(host: String, luns: [NetzLun]) { self.host = host; self.luns = luns } }
public struct SuchErgebnis: Equatable { public var usb: [ErkannteDrobo]; public var lan: [LanDrobo]; public var lanFehler: String? }

/// "Drobos suchen": USB (bestehende Erkennung) und LAN (ueber den Hilfsdienst, danach je Fund die Volumes). Nichts wird uebernommen; der Aufrufer bietet an.
/// `lanHosts` / `lunsFuer` sind austauschbar (Tests); Vorgabe = Hilfsdienst. `ausnehmen`: Adressen eingehaengter DroboPros (keine zweite Sitzung).
/// `bekannt`: Adressen schon eingerichteter Drobos. Ein LAN-Treffer darunter bekommt die Weckphase (eine Sitzung, TEST UNIT READY bis bereit), bevor die Volumes gelesen werden;
/// `weckfortschritt(host, Sekunden)` meldet den Fortschritt.
public func drobosSuchen(lan: Bool = true, ausnehmen: Set<String> = [], bekannt: Set<String> = [], usbVendor: String = "Drobo",
                         lanHosts: ((Set<String>) throws -> [String])? = nil,
                         lunsFuer: ((String) throws -> [NetzLun])? = nil, weckfortschritt: ((String, Int) -> Void)? = nil, weckfehler: ((String, Error) -> Void)? = nil) -> SuchErgebnis {
    let hostsHolen = lanHosts ?? { try helferISCSISuche(ausnehmen: $0, bekannte: bekannt) }
    let lunsHolen = lunsFuer ?? { h in
        do { return try netzEntdecken(host: h, aufwecken: bekannt.contains(h), fortschritt: { weckfortschritt?(h, $0) }) } catch { if bekannt.contains(h) { weckfehler?(h, error) }; throw error }
    }
    var r = SuchErgebnis(usb: erkenneDrobos(vendor: usbVendor), lan: [], lanFehler: nil)
    guard lan else { return r }
    do { r.lan = try hostsHolen(ausnehmen).map { h in LanDrobo(host: h, luns: (try? lunsHolen(h)) ?? []) } }
    catch { r.lanFehler = "\(error)" }
    return r
}
