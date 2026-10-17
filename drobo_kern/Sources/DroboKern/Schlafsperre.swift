import Foundation
import IOKit.pwr_mgt

/// Verhindert den Ruhezustand des Macs, solange ein kritischer Vorgang laeuft (Formatieren, Sichern, Schreiben-Einhaengen, Zurueckspielen, Wecken): schlaeft der Mac mitten darin ein,
/// reisst die iSCSI-Verbindung ab und die DroboPro startet neu. Die Assertion `PreventUserIdleSystemSleep` hindert den Leerlauf-Ruhezustand; Deckel zu oder Ausschalten
/// verhindert sie nicht (dafuer die Warnung beim Beenden und die Mitteilung vor dem Ausschalten).
/// Freigabe IMMER per defer, auch bei Fehler. Die API ist austauschbar (Test).
public struct SchlafsperreAPI {
    public var anlegen: (String) -> UInt32?
    public var loesen: (UInt32) -> Void
    public init(anlegen: @escaping (String) -> UInt32?, loesen: @escaping (UInt32) -> Void) { self.anlegen = anlegen; self.loesen = loesen }
    public static let system = SchlafsperreAPI(
        anlegen: { name in
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            return rc == kIOReturnSuccess ? id : nil
        },
        loesen: { _ = IOPMAssertionRelease($0) })
}

/// Haelt die Sperre fuer die Dauer von `arbeit`. Der Name steht im Systembericht (`pmset -g assertions`): "DroboDraft: <Vorgang> <Drobo>".
public func mitSchlafsperre<T>(_ name: String, api: SchlafsperreAPI = .system, _ arbeit: () async throws -> T) async rethrows -> T {
    let id = api.anlegen(name)
    defer { if let id { api.loesen(id) } }
    return try await arbeit()
}
