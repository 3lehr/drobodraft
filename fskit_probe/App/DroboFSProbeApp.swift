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

@main
struct DroboFSProbeApp: App {
    init() {
        // Kopflauf ohne Fenster: DroboFSProbe --helfer-status | --helfer-registrieren
        let a = CommandLine.arguments
        if a.contains("--helfer-neu") { try? SMAppService.daemon(plistName: helferPlist).unregister(); print("unregister status=\(helferStatusText())") }
        if a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print(helferRegistrieren()) }
        if a.contains("--helfer-status") || a.contains("--helfer-registrieren") || a.contains("--helfer-neu") { print("status=\(helferStatusText())"); exit(0) }
    }
    var body: some Scene { WindowGroup { HelferAnsicht() } }
}

struct HelferAnsicht: View {
    @State private var status = helferStatusText()
    @State private var meldung = ""
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
            Text(meldung)
        }.padding()
    }
}
