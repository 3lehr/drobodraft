import ServiceManagement
import SwiftUI

// Traeger der FSKit-Extension + Registrierung des Hilfsdienstes (UI minimal, Design kommt spaeter).
let helferPlist = "de.begod.drobohelper.plist"

func helferStatusText() -> String {
    switch SMAppService.daemon(plistName: helferPlist).status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unbekannt"
    }
}

func helferRegistrieren() -> String {
    do { try SMAppService.daemon(plistName: helferPlist).register(); return "register ok" }
    catch { return "register Fehler: \(error)" }
}

let drobo_UUID = "C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1"

/// Prueft, ob DIESER Prozess (die App) das Roh-Geraet der Partition oeffnen darf. Nur O_RDONLY|O_NONBLOCK, sofort close, nie lesen/schreiben.
/// Beim ersten Mal fragt macOS nach Zugriff auf Wechseldatentraeger (Dialog gehoert dem Betreiber); der Dienst erbt die Erlaubnis.
func zugriffOeffnen(_ uuid: String) -> String {
    guard let m = finden(uuid: uuid) else { return "kein Volume mit UUID \(uuid) gefunden" }
    guard m.bsd.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else { return "\(m.bsd) ist keine Partition (abgelehnt)" }
    let fd = open(m.rohgeraet, O_RDONLY | O_NONBLOCK)
    if fd < 0 { let e = errno; return "open \(m.rohgeraet): errno=\(e) (\(String(cString: strerror(e))))" }
    close(fd)
    return "open \(m.rohgeraet): ok"
}

func kopfOpt(_ n: String) -> String? { let a = CommandLine.arguments; if let i = a.firstIndex(of: n), i + 1 < a.count { return a[i + 1] }; return nil }

@main
struct DroboFSProbeApp: App {
    init() {
        // Kopflauf ohne Fenster: DroboFSProbe --helfer-status | --helfer-registrieren
        let a = CommandLine.arguments
        if a.contains("--zugriff-anfragen") || a.contains("--zugriff-status") {
            if a.contains("--zugriff-anfragen") { print("macOS fragt jetzt ggf. nach Zugriff auf Wechseldatentraeger -> Erlauben") }
            print(zugriffOeffnen(kopfOpt("--uuid") ?? drobo_UUID)); exit(0)
        }
        if a.contains("--helfer-neu") { try? SMAppService.daemon(plistName: helferPlist).unregister(); print("unregister status=\(helferStatusText())") }
        if a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print(helferRegistrieren()) }
        if a.contains("--helfer-status") || a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print("status=\(helferStatusText())"); exit(0) }
    }
    var body: some Scene { WindowGroup { HelferAnsicht() } }
}

struct HelferAnsicht: View {
    @State private var status = helferStatusText()
    @State private var meldung = ""
    @State private var zugriff = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("drobofsprobe: Host fuer FSKit-Modul")
            Text("Hilfsdienst: \(status)")
            if status == "requiresApproval" { Text("Freischalten: Systemeinstellungen > Allgemein > Anmeldeobjekte und Erweiterungen > Drobo-Hilfsdienst einschalten.") }
            HStack {
                Button("Hilfsdienst registrieren") { meldung = helferRegistrieren(); status = helferStatusText() }
                Button("Systemeinstellungen oeffnen") { SMAppService.openSystemSettingsLoginItems() }
                Button("Status neu lesen") { status = helferStatusText() }
            }
            Button("Zugriff auf Drobo erlauben") { zugriff = zugriffOeffnen(drobo_UUID) }
            Text("macOS fragt danach nach Zugriff auf Wechseldatentraeger: Erlauben klicken, dann diesen Knopf erneut. Es wird nichts gelesen oder geschrieben.")
            Text(zugriff)
            Text(meldung)
        }.padding()
    }
}
