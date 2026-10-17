import Foundation

public struct LanDrobo: Equatable { public var host: String; public var luns: [NetzLun] }
public struct SuchErgebnis: Equatable { public var usb: [ErkannteDrobo]; public var lan: [LanDrobo]; public var lanFehler: String? }

/// "Drobos suchen": USB (bestehende Erkennung) und LAN (ueber den Hilfsdienst, danach je Fund die Volumes). Nichts wird uebernommen; der Aufrufer bietet an.
/// `lanHosts` / `lunsFuer` sind austauschbar (Tests); Vorgabe = Hilfsdienst. `ausnehmen`: Adressen eingehaengter DroboPros (keine zweite Sitzung).
public func drobosSuchen(lan: Bool = true, ausnehmen: Set<String> = [], usbVendor: String = "Drobo",
                         lanHosts: (Set<String>) throws -> [String] = { try helferISCSISuche(ausnehmen: $0) },
                         lunsFuer: (String) throws -> [NetzLun] = { try netzEntdecken(host: $0) }) -> SuchErgebnis {
    var r = SuchErgebnis(usb: erkenneDrobos(vendor: usbVendor), lan: [], lanFehler: nil)
    guard lan else { return r }
    do { r.lan = try lanHosts(ausnehmen).map { h in LanDrobo(host: h, luns: (try? lunsFuer(h)) ?? []) } }
    catch { r.lanFehler = "\(error)" }
    return r
}
