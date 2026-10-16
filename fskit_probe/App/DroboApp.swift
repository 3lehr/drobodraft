import DroboKern
import SwiftUI

@main
struct DroboApp: App {
    @StateObject private var modell = DroboModell()

    init() {
        if kopflauf() { exit(0) }
    }

    var body: some Scene {
        Window("DroboDraft", id: "haupt") {
            HauptAnsicht().environmentObject(modell)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { modell.starten() }
        }
        .commands {
            // Standard-Menue "Schliessen" (⌘W) ersetzen: ⌘W gehoert laut Auftrag "Zum Schreiben neu"
            HilfeBefehle()
            CommandGroup(replacing: .appInfo) { Button("Über DroboDraft") { ueberFenster() } }
            CommandMenu("Volume") {
                Button("Im Finder öffnen") { modell.imFinderOeffnen() }.keyboardShortcut("o", modifiers: .command).disabled(modell.aktuell?.eingehaengt != true)
                Button("Aushängen") { modell.aushaengen() }.keyboardShortcut("e", modifiers: .command).disabled(modell.aktuell?.eingehaengt != true || modell.arbeit != nil)
                Button("Zum Schreiben neu …") { NotificationCenter.default.post(name: .schreibenFrage, object: nil) }
                    .disabled(modell.aktuell?.eingehaengt != true || modell.aktuell?.nurlesen != true)
                Divider()
                Button("Aktualisieren") { modell.aktualisieren() }.keyboardShortcut("r", modifiers: .command)
            }
        }
        Window("DroboDraft Hilfe", id: "hilfe") { HilfeAnsicht() }
        MenuBarExtra {
            MenueleistenInhalt().environmentObject(modell)
        } label: {
            Label("DroboDraft", systemImage: modell.aktuell.map { $0.stufe == .warnung ? "exclamationmark.triangle.fill" : ($0.eingehaengt ? "externaldrive.fill" : "externaldrive") } ?? "externaldrive")
        }
        Settings { EinstellungenAnsicht().environmentObject(modell) }
    }
}

extension Notification.Name { static let schreibenFrage = Notification.Name("drobodraft.schreibenFrage") }

/// Über-Fenster: Name, Version, Kennzeichnung als frühe Alpha.
func ueberFenster() {
    let text = NSMutableAttributedString(string: String(localized: "Frühe Alpha. Funktionen und Oberfläche ändern sich noch; nicht für den Dauerbetrieb gedacht.\n\nDroboDraft hängt eine Drobo über das Treibermodul ein und sichert vorher die Verwaltungsdaten des Laufwerks."))
    text.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: NSRange(location: 0, length: text.length))
    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DroboDraft", .applicationVersion: "0.1.0 (Frühe Alpha)", .version: "3", .credits: text])
    NSApp.activate(ignoringOtherApps: true)
}

struct HilfeBefehle: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) { Button("DroboDraft Hilfe") { openWindow(id: "hilfe") }.keyboardShortcut("?", modifiers: .command) }
    }
}
