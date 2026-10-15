import Foundation

/// Freigabeliste des Moduls (Gate.swift im Modul liest dieselbe Datei). Format: [{"volume_uuid","modus","max_bytes"}] oder {"eintraege":[...]}.
public enum Freigabe {
    public static var standardPfad: String {
        ProcessInfo.processInfo.environment["DROBO_FREIGABE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/Library/Containers/de.begod.drobofsprobe.fsmodule/Data/freigabe.json"
    }

    private static func laden(_ pfad: String) throws -> (eintraege: [[String: Any]], alsDict: Bool) {
        guard FileManager.default.fileExists(atPath: pfad) else { return ([], false) }
        guard let d = FileManager.default.contents(atPath: pfad), let j = try? JSONSerialization.jsonObject(with: d) else {
            throw Fehler.freigabeDatei("\(pfad) unlesbar oder kein JSON (nichts geaendert)")
        }
        if let a = j as? [[String: Any]] { return (a, false) }
        if let o = j as? [String: Any], let a = o["eintraege"] as? [[String: Any]] { return (a, true) }
        throw Fehler.freigabeDatei("\(pfad) hat unbekanntes Format (nichts geaendert)")
    }

    public static func lesen(uuid: String, pfad: String = standardPfad) throws -> Modus? {
        let e = try laden(pfad).eintraege.first { ($0["volume_uuid"] as? String)?.uppercased() == uuid.uppercased() }
        return (e?["modus"] as? String).flatMap(Modus.init(rawValue:))
    }

    /// Setzt den Modus; bestehender Eintrag behaelt max_bytes, ein neuer braucht `maxBytes`. Andere Eintraege bleiben unveraendert.
    public static func setzen(uuid: String, modus: Modus, maxBytes: UInt64?, pfad: String = standardPfad) throws {
        var (liste, alsDict) = try laden(pfad)
        let u = uuid.uppercased()
        if let i = liste.firstIndex(where: { ($0["volume_uuid"] as? String)?.uppercased() == u }) {
            liste[i]["modus"] = modus.rawValue
        } else {
            guard let mb = maxBytes else { throw Fehler.freigabeDatei("neuer Eintrag ohne max_bytes (Volume nicht angeschlossen?)") }
            liste.append(["volume_uuid": u, "modus": modus.rawValue, "max_bytes": NSNumber(value: mb)])
        }
        let obj: Any = alsDict ? ["eintraege": liste] : liste
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(atPath: (pfad as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try d.write(to: URL(fileURLWithPath: pfad), options: .atomic)
    }
}
