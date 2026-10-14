import SwiftUI

// Nur Träger der FSKit-Extension (App-Extension braucht eine Host-App).
@main
struct DroboFSProbeApp: App {
    var body: some Scene {
        WindowGroup { Text("drobofsprobe: Host fuer FSKit-Modul") }
    }
}
