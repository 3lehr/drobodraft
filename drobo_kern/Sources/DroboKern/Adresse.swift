import Foundation

/// Name des iSCSI-Ziels (IQN) der Netzwerk-Drobo ueber den Hilfsdienst (Discovery-Sitzung, nur lesend). Die IQN bleibt bei IP-Wechsel gleich.
public func netzZielName(host: String) throws -> String {
    let port = try helferISCSIWeiterleitung(host: host)
    let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: 10); defer { d.abmelden() }
    guard let z = try d.ziele().first?.name else { throw ISCSIFehler.protokoll("target offers no name") }
    return z
}

/// Wechselt die IP einer DroboPro, wird sie ueber die feste IQN wiedergefunden: LAN-Suche (Hilfsdienst), je Fund die IQN erfragen, Treffer mit GLEICHER IQN gilt.
/// Falsche oder fehlende IQN -> nil (nie umschreiben, nie raten). `ausnehmen` = Adressen eingehaengter Geraete (keine zweite Sitzung).
public func netzAdresseSuchen(iqn: String, ausnehmen: Set<String> = [], lanHosts: (Set<String>) throws -> [String] = { try helferISCSISuche(ausnehmen: $0) },
                              iqnFuer: (String) throws -> String? = { try? netzZielName(host: $0) }) -> String? {
    guard !iqn.isEmpty, let hosts = try? lanHosts(ausnehmen) else { return nil }
    for h in hosts { if let z = try? iqnFuer(h), z == iqn { return h } }
    return nil
}
