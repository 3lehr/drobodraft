import DroboKern
import SwiftUI

@main
struct DroboApp: App {
    @StateObject private var modell = DroboModell()

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
                .onAppear { modell.starten() }
        }
        .commands { DroboBefehle(m: modell) }
        Window("DroboDraft Hilfe", id: "hilfe") { HilfeAnsicht() }
        MenuBarExtra {
            MenueleistenInhalt().environmentObject(modell)
        } label: {
            Label("DroboDraft", systemImage: modell.gesamtSchwere == .kritisch ? "xmark.octagon.fill" : (modell.gesamtSchwere == .warnung || modell.aktuell?.stufe == .warnung ? "exclamationmark.triangle.fill" : (modell.aktuell?.eingehaengt == true ? "externaldrive.fill" : "externaldrive")))
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
