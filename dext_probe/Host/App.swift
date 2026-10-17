import SwiftUI
import SystemExtensions
import IOKit

// Nur Aktivierung des Test-Dext. Der Betreiber bestaetigt in den Systemeinstellungen.
// Nur aus /Applications startbar (OSSystemExtensionRequest verlangt das).
private let dextID = "de.begod.drobo.dextprobe.dext"

final class Activator: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Nicht angefordert" { didSet { print("STATUS: \(status)"); fflush(stdout) } }

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
    init() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--probe"), i + 1 < a.count, let c = UInt64(a[i + 1]) { fflush(stdout); exit(probe(c)) }
    }
    @StateObject private var a = Activator()
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(a.status)
                Button("Dext aktivieren") { a.activate() }
            }.padding()
            .onAppear { if CommandLine.arguments.contains("--activate") { a.activate() } }  // Kopflauf: DextProbeHost --activate
        }
    }
}

// Kopflauf: DextProbeHost --probe 1|2  (1 = INQUIRY, 2 = MODE SENSE(10) 0x3F) -> UserClient des Dext, Antworttext auf stdout
func probe(_ cmd: UInt64) -> Int32 {
    var it: io_iterator_t = 0
    IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it)
    var svc: io_service_t = 0
    while case let s = IOIteratorNext(it), s != 0 {
        if let u = IORegistryEntryCreateCFProperty(s, "IOUserClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, u == "MaxWriteProbe" { svc = s; break }
        IOObjectRelease(s)
    }
    guard svc != 0 else { print("kein MaxWriteProbe-Dienst"); return 2 }
    var c: io_connect_t = 0
    let o = IOServiceOpen(svc, mach_task_self_, 0, &c)
    print(String(format: "IOServiceOpen ret=0x%x", UInt32(bitPattern: o)))
    guard o == 0 else { return 1 }
    var input = cmd
    var out = [CChar](repeating: 0, count: 512)
    var n = out.count
    let r = IOConnectCallMethod(c, 0, &input, 1, nil, 0, nil, nil, &out, &n)
    print(String(format: "cmd=%llu call ret=0x%x out=%@", cmd, UInt32(bitPattern: r), String(cString: out)))
    IOServiceClose(c)
    return r == 0 ? 0 : 1
}
