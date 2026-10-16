import DroboKern
import SwiftUI

@main
struct DroboApp: App {
    @StateObject private var modell = DroboModell()

    init() {
        if kopflauf() { exit(0) }
    }

    var body: some Scene {
        Window("Drobo", id: "haupt") {
            HauptAnsicht().environmentObject(modell)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { modell.starten() }
        }
        .commands {
            // Standard-Menue "Schliessen" (⌘W) ersetzen: ⌘W gehoert laut Auftrag "Zum Schreiben neu"
            CommandGroup(replacing: .saveItem) { Button("Fenster schließen") { NSApp.keyWindow?.close() }.keyboardShortcut("w", modifiers: [.command, .shift]) }
            CommandMenu("Volume") {
                Button("Im Finder öffnen") { modell.imFinderOeffnen() }.keyboardShortcut("o", modifiers: .command).disabled(modell.aktuell?.eingehaengt != true)
                Button("Aushängen") { modell.aushaengen() }.keyboardShortcut("e", modifiers: .command).disabled(modell.aktuell?.eingehaengt != true || modell.arbeit != nil)
                Button("Zum Schreiben neu …") { NotificationCenter.default.post(name: .schreibenFrage, object: nil) }.keyboardShortcut("w", modifiers: .command)
                    .disabled(modell.aktuell?.eingehaengt != true || modell.aktuell?.nurlesen != true)
                Divider()
                Button("Aktualisieren") { modell.aktualisieren() }.keyboardShortcut("r", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenueleistenInhalt().environmentObject(modell)
        } label: {
            Label("Drobo", systemImage: modell.aktuell.map { $0.stufe == .warnung ? "exclamationmark.triangle.fill" : ($0.eingehaengt ? "externaldrive.fill" : "externaldrive") } ?? "externaldrive")
        }
        Settings { EinstellungenAnsicht().environmentObject(modell) }
    }
}

extension Notification.Name { static let schreibenFrage = Notification.Name("de.begod.drobo.schreibenFrage") }
