import Foundation
import Security

/// Bundle-Praefix und Team an einer Stelle: zur Laufzeit gelesen, nicht fest eingebaut.
/// Quelle des Praefixes (erste Treffer gewinnt): Umgebung DROBO_BUNDLE_PREFIX (CLI, Tests) -> eigene Bundle-Kennung (App ".drobofsprobe",
/// Dienst ".drobohelper") -> die installierte App -> Vorgabe. Das Team liest der Dienst aus seiner eigenen Code-Signatur.
/// Gesetzt wird beides beim Bauen in fskit_probe/Identity.xcconfig (bzw. Identity.local.xcconfig).
public enum Identitaet {
    public static let vorgabePrefix = "de.begod"
    static let appSuffix = ".drobofsprobe"

    public static let prefix: String = {
        if let e = ProcessInfo.processInfo.environment["DROBO_BUNDLE_PREFIX"], !e.isEmpty { return e }
        if let id = Bundle.main.bundleIdentifier { for s in [appSuffix, ".drobohelper"] where id.hasSuffix(s) { return String(id.dropLast(s.count)) } }
        if let id = Bundle(path: "/Applications/DroboFSProbe.app")?.bundleIdentifier, id.hasSuffix(appSuffix) { return String(id.dropLast(appSuffix.count)) }
        return vorgabePrefix
    }()

    /// Team-ID der eigenen Code-Signatur (nil, wenn nicht oder ad hoc signiert).
    public static func eigenesTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let c = code else { return nil }
        var statisch: SecStaticCode?
        guard SecCodeCopyStaticCode(c, [], &statisch) == errSecSuccess, let s = statisch else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(s, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Anforderung an den Aufrufer des Dienstes: Zertifikat desselben Teams, Kennung App oder CLI.
public func anforderung(prefix: String, team: String) -> String {
    "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (identifier \"\(prefix).drobofsprobe\" or identifier \"\(prefix).drobo\")"
}
