import DroboKern
import SwiftUI

struct EinstellungenAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @State private var anleitung = false
    @State private var neuName = ""
    @State private var neuKennung = ""

    func ordnerWaehlen(_ start: String) -> String? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: start); p.prompt = String(localized: "Wählen")
        return p.runModal() == .OK ? p.url?.path : nil
    }

    var body: some View {
        Form {
            Section("Einhängen") {
                HStack {
                    TextField("Einhängeort", text: $m.einstellungen.einhaengeort).onSubmit { m.einstellungenSpeichern() }
                    Button("Wählen …") { if let p = ordnerWaehlen(m.einstellungen.einhaengeort) { m.einstellungen.einhaengeort = p; m.einstellungenSpeichern() } }
                }
                Text("Der Ort darf nicht in Ihrem Benutzerordner liegen, sonst indexiert Spotlight das Laufwerk.").font(.callout).foregroundStyle(.secondary)
                Picker("Vorgabe beim Einhängen", selection: $m.einstellungen.vorgabeSchreiben) {
                    Text("Nur lesen").tag(false)
                    Text("Schreiben").tag(true)
                }.onChange(of: m.einstellungen.vorgabeSchreiben) { _, _ in m.einstellungenSpeichern() }
            }
            Section("Sicherung der Verwaltungsdaten") {
                HStack {
                    TextField("Sicherungsort", text: $m.einstellungen.sicherungOrt).onSubmit { m.einstellungenSpeichern() }
                    Button("Wählen …") { if let p = ordnerWaehlen(m.einstellungen.sicherungOrt) { m.einstellungen.sicherungOrt = p; m.einstellungenSpeichern() } }
                }
                Stepper("Aufbewahrte Sicherungen: \(m.einstellungen.sicherungAnzahl)", value: $m.einstellungen.sicherungAnzahl, in: 1...20).onChange(of: m.einstellungen.sicherungAnzahl) { _, _ in m.einstellungenSpeichern() }
                Text("Nicht auf dem Startvolume und nicht auf der Drobo selbst. Ältere Sicherungen werden erst gelöscht, wenn die neue gelungen und geprüft ist.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Spotlight und Time Machine") {
                Toggle("Ich habe die Drobo bei Spotlight und Time Machine ausgeschlossen", isOn: $m.einstellungen.spotlightAusgeschlossen).onChange(of: m.einstellungen.spotlightAusgeschlossen) { _, _ in m.einstellungenSpeichern() }
                Text("Freiwillig. Solange das aus ist, weist die App beim Schreiben darauf hin.").font(.callout).foregroundStyle(.secondary)
                Button("Anleitung …") { anleitung = true }
            }
            Section("Mitteilungen") {
                Toggle("Mitteilungen bei Anschluss, Trennung und Warnungen", isOn: $m.einstellungen.mitteilungen).onChange(of: m.einstellungen.mitteilungen) { _, _ in m.einstellungenSpeichern() }
            }
            Section("Drobos") {
                ForEach(m.einstellungen.drobos, id: \.uuid) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        Picker("Rolle von \(d.name)", selection: Binding(get: { d.rolle }, set: { r in
                            if let i = m.einstellungen.drobos.firstIndex(where: { $0.uuid == d.uuid }) { m.einstellungen.drobos[i].rolle = r; m.einstellungenSpeichern() } })) {
                            Text("Arbeitsvolume").tag(Rolle.arbeitsvolume)
                            Text("Time Machine (nur anzeigen)").tag(Rolle.timemachine)
                        }.labelsHidden().frame(maxWidth: 260)
                        if m.einstellungen.drobos.count > 1 {
                            Button(role: .destructive) { m.einstellungen.drobos.removeAll { $0.uuid == d.uuid }; m.einstellungenSpeichern() } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("\(d.name) entfernen")
                        }
                    }
                }
                HStack {
                    TextField("Name", text: $neuName)
                    TextField("Volume-Kennung", text: $neuKennung)
                    Button("Hinzufügen") {
                        let k = neuKennung.trimmingCharacters(in: .whitespaces)
                        guard !neuName.isEmpty, UUID(uuidString: k) != nil else { m.meldung = Meldung(titel: "Drobo", text: String(localized: "Name und eine gültige Volume-Kennung eingeben.")); return }
                        m.einstellungen.drobos.append(DroboEintrag(uuid: k, name: neuName)); neuName = ""; neuKennung = ""; m.einstellungenSpeichern()
                    }
                }
            }
            Section("Hilfsdienst") {
                LabeledContent("Status", value: m.hilfsdienst)
                HStack {
                    Button("Einrichten") { m.dienstRegistrieren() }
                    Button("Systemeinstellungen öffnen") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                }
                Text("Der Hilfsdienst gibt nur den Gerätezugang genau dieser Drobo frei. Er benötigt einmalig Ihre Freigabe unter Anmeldeobjekte und den Festplattenvollzugriff.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 560)
        .sheet(isPresented: $anleitung) { SpotlightAnleitung() }
    }
}

struct MenueleistenInhalt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let a = m.aktuell {
            Text("\(a.eintrag.name): \(a.zustandText)")
            if m.liste.count > 1 {
                Picker("Drobo", selection: $m.auswahl) { ForEach(m.liste, id: \.eintrag.uuid) { Text($0.eintrag.name).tag($0.eintrag.uuid) } }
            }
            Divider()
            Button("Im Finder öffnen") { m.imFinderOeffnen() }.keyboardShortcut("o", modifiers: .command).disabled(!a.eingehaengt)
            Button("Aushängen") { m.aushaengen() }.keyboardShortcut("e", modifiers: .command).disabled(!a.eingehaengt || m.arbeit != nil)
        }
        Divider()
        Button("Fenster öffnen …") { openWindow(id: "haupt"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Einstellungen …") }.keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Drobo beenden") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
