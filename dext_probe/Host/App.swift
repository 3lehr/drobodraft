import SwiftUI
import SystemExtensions

// Nur Aktivierung des Test-Dext. Der Betreiber bestaetigt in den Systemeinstellungen.
// Nur aus /Applications startbar (OSSystemExtensionRequest verlangt das).
private let dextID = "de.begod.drobo.dextprobe.dext"

final class Activator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Nicht angefordert"

    func activate() {
        status = "Anforderung gesendet"
        OSSystemExtensionManager.shared.submitRequest(
            OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: dextID, queue: .main).withDelegate(self))
    }
    func request(_ r: OSSystemExtensionRequest, didFinishWithResult res: OSSystemExtensionRequest.Result) { status = "Fertig: \(res.rawValue)" }
    func request(_ r: OSSystemExtensionRequest, didFailWithError e: Error) { status = "Fehler: \(e)" }
    func requestNeedsUserApproval(_ r: OSSystemExtensionRequest) { status = "Wartet auf Freigabe in den Systemeinstellungen" }
    func request(_ r: OSSystemExtensionRequest, actionForReplacingExtension o: OSSystemExtensionProperties, withExtension n: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}

private extension OSSystemExtensionRequest {
    func withDelegate(_ d: OSSystemExtensionRequestDelegate) -> OSSystemExtensionRequest { delegate = d; return self }
}

@main
struct DextProbeApp: App {
    @StateObject private var a = Activator()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text(a.status)
                Button("Dext aktivieren") { a.activate() }
            }.padding(24)
        }
    }
}
