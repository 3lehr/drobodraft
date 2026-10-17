import SwiftUI
import SystemExtensions

// Nur Aktivierung des Blockbruecke-Dext (Plan Schritt 1). Gleicher Weg wie dext_probe/Host/App.swift.
// Der Betreiber bestaetigt in den Systemeinstellungen. Nur aus /Applications startbar (OSSystemExtensionRequest verlangt das).
private let dextID = "de.begod.drobo.blockbruecke.dext"

final class Activator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Nicht angefordert" { didSet { print("STATUS: \(status)"); fflush(stdout) } }

    func submit(_ r: OSSystemExtensionRequest, _ s: String) { status = s; r.delegate = self; OSSystemExtensionManager.shared.submitRequest(r) }
    func activate() { submit(.activationRequest(forExtensionWithIdentifier: dextID, queue: .main), "Aktivierung angefordert") }
    func deactivate() { submit(.deactivationRequest(forExtensionWithIdentifier: dextID, queue: .main), "Deaktivierung angefordert") }

    func request(_ r: OSSystemExtensionRequest, didFinishWithResult res: OSSystemExtensionRequest.Result) { status = "Fertig: \(res.rawValue)" }
    func request(_ r: OSSystemExtensionRequest, didFailWithError e: Error) { status = "Fehler: \(e)" }
    func requestNeedsUserApproval(_ r: OSSystemExtensionRequest) { status = "Wartet auf Freigabe in den Systemeinstellungen" }
    func request(_ r: OSSystemExtensionRequest, actionForReplacingExtension o: OSSystemExtensionProperties, withExtension n: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}

@main
struct BlockbrueckeApp: App {
    @StateObject private var a = Activator()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text(a.status).accessibilityAddTraits(.updatesFrequently)
                Button("Treiber aktivieren") { a.activate() }.keyboardShortcut(.defaultAction)
                Button("Treiber deaktivieren") { a.deactivate() }
            }.padding()
            .onAppear {   // Kopflauf: BlockbrueckeHost --activate | --deactivate
                if CommandLine.arguments.contains("--activate") { a.activate() }
                if CommandLine.arguments.contains("--deactivate") { a.deactivate() }
            }
        }
    }
}
