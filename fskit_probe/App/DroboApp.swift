import DroboKern
import SwiftUI

@main
struct DroboApp: App {
    @StateObject private var modell = DroboModell()
    @NSApplicationDelegateAdaptor(DroboAppDelegate.self) private var appDelegate

    init() {
        if kopflauf() { exit(0) }
        #if DEBUG
        // Testlaeufe ohne sichtbares Fenster: kein Dock-Symbol, Fenster werden in Modell.starten() ausgeblendet (Steuerung per Text braucht keins)
        if ProcessInfo.processInfo.environment["DROBO_DEMO_HINTEN"] != nil { NSApplication.shared.setActivationPolicy(.accessory) }
        #endif
    }

    var body: some Scene {
        Window("DroboDraft", id: "haupt") {
            HauptAnsicht().environmentObject(modell)
                .frame(minWidth: Mass.fensterBreiteMin, minHeight: Mass.fensterHoeheMin)
                .onAppear { DroboAppDelegate.modell = modell; modell.starten() }
        }
        .commands { DroboBefehle(m: modell) }
        Window("DroboDraft Hilfe", id: "hilfe") { HilfeAnsicht() }
        MenuBarExtra {
            MenueleistenInhalt().environmentObject(modell)
        } label: {
            Label("DroboDraft", systemImage: !modell.vorgaenge.isEmpty ? "hourglass" : modell.gesamtSchwere == .kritisch ? "xmark.octagon.fill" : (modell.gesamtSchwere == .warnung || modell.aktuell?.stufe == .warnung ? "exclamationmark.triangle.fill" : (modell.aktuell?.eingehaengt == true ? "externaldrive.fill" : "externaldrive")))
        }
        Settings { EinstellungenAnsicht().environmentObject(modell) }
    }
}

/// Über-Fenster: Name, Version, Kennzeichnung als frühe Alpha.
func ueberFenster() {
    let text = NSMutableAttributedString(string: String(localized: "Frühe Alpha. Funktionen und Oberfläche ändern sich noch; nicht für den Dauerbetrieb gedacht.\n\nDroboDraft hängt eine Drobo über das Treibermodul ein und sichert vorher die Verwaltungsdaten des Laufwerks."))
    text.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: NSRange(location: 0, length: text.length))
    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DroboDraft", .applicationVersion: "0.1.0 (Frühe Alpha)", .version: "3", .credits: text])
    NSApp.activate(ignoringOtherApps: true)
}

/// Beenden waehrend eines kritischen Vorgangs: Warnblatt, "Abbrechen" ist die Vorgabe (Eingabetaste). Beenden mitten im Formatieren/Sichern/Schreiben kann Daten beschaedigen.
final class DroboAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var modell: DroboModell?
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let v = Self.modell?.vorgaenge.values.first else { return .terminateNow }
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = String(localized: "Vorgang läuft — trotzdem beenden?")
        a.informativeText = String(localized: "\(v.titel) an \(v.drobo) ist noch nicht fertig. Wenn du jetzt beendest, kann die Drobo oder ihr Volume beschädigt werden.")
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.addButton(withTitle: String(localized: "Trotzdem beenden"))
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
