import DroboKern
import SwiftUI

struct EinstellungenAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @State private var anleitung = false
    @State private var neuName = ""
    @State private var neuKennung = ""
    @State private var sicherungsort = ""

    func ordnerWaehlen(_ start: String) -> String? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: start); p.prompt = String(localized: "Wählen")
        return p.runModal() == .OK ? p.url?.path : nil
    }

    var body: some View {
        Form {
            Section("Einhängen") {
                Picker("Einhängeort", selection: Binding(get: { m.einstellungen.einhaengeort == vorgabeOrt ? vorgabeOrt : vorgabeVolumes }, set: { v in m.aendern(String(localized: "Einhängeort ändern")) { $0.einhaengeort = v } })) {
                    Text("Im Finder sichtbar (unter „Orte“)").tag(vorgabeVolumes)
                    Text("Verdeckt (nur über „Im Finder öffnen“)").tag(vorgabeOrt)
                }
                Text("Sichtbar: das Laufwerk erscheint wie jedes andere im Finder. Spotlight läuft dort nach Messung nicht hinein. Der Ordner wird vom Hilfsdienst angelegt und beim Aushängen wieder entfernt. Der Ort darf nie im Benutzerordner liegen.").font(.callout).foregroundStyle(.secondary)
                Picker("Vorgabe beim Einhängen", selection: m.binding(\.vorgabeSchreiben, String(localized: "Vorgabe beim Einhängen ändern"))) {
                    Text("Nur lesen").tag(false)
                    Text("Schreiben").tag(true)
                }
            }
            Section("Sicherung der Verwaltungsdaten") {
                HStack {
                    TextField("Sicherungsort", text: $sicherungsort, prompt: Text("noch nicht gewählt")).onSubmit { m.aendern(String(localized: "Sicherungsort ändern")) { $0.sicherungOrt = sicherungsort } }
                    Button("Wählen …") { if let p = ordnerWaehlen(m.einstellungen.sicherungOrt) { m.fuehreAus(.sicherungsortWaehlen, arg: p) } }
                }
                Stepper("Aufbewahrte Sicherungen: \(m.einstellungen.sicherungAnzahl)", value: m.binding(\.sicherungAnzahl, String(localized: "Anzahl der Sicherungen ändern")), in: 1...20)
                Text("Nicht auf dem Startvolume und nicht auf der Drobo selbst. Ältere Sicherungen werden erst gelöscht, wenn die neue gelungen und geprüft ist.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Spotlight und Time Machine") {
                Toggle("Ich habe die Drobo bei Spotlight und Time Machine ausgeschlossen", isOn: m.binding(\.spotlightAusgeschlossen, String(localized: "Spotlight-Ausschluss ändern")))
                Text("Freiwillig. Solange das aus ist, weist die App beim Schreiben darauf hin.").font(.callout).foregroundStyle(.secondary)
                Button("Anleitung …") { anleitung = true }
            }
            Section("Start") {
                Toggle("Beim Anmelden starten", isOn: Binding(get: { m.anmeldeStart }, set: { m.anmeldeStartSetzen($0) }))
                Text("Standard: aus. Die App startet dann beim Anmelden im Hintergrund mit Symbol in der Menüleiste.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Mitteilungen") {
                Toggle("Mitteilungen bei Anschluss, Trennung und Warnungen", isOn: m.binding(\.mitteilungen, String(localized: "Mitteilungen ändern")))
            }
            Section("Drobos") {
                ForEach(m.einstellungen.drobos, id: \.uuid) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        if d.netz != nil { Text("Netzwerk (iSCSI)").foregroundStyle(.secondary) } else { Picker("Rolle von \(d.name)", selection: Binding(get: { d.rolle }, set: { r in
                            m.aendern(String(localized: "Rolle ändern")) { e in if let i = e.drobos.firstIndex(where: { $0.uuid == d.uuid }) { e.drobos[i].rolle = r } } })) {
                            Text("Arbeitsvolume").tag(Rolle.arbeitsvolume)
                            Text("Time Machine (nur anzeigen)").tag(Rolle.timemachine)
                        }.labelsHidden().frame(maxWidth: Mass.rolleAuswahl) }
                        if m.einstellungen.drobos.count > 1 {
                            Button(role: .destructive) { m.entfernen(d.uuid) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel("\(d.name) entfernen")
                        }
                    }
                }
                ForEach(m.erkannte, id: \.uuid) { e in
                    HStack { Text("Erkannt: \(e.name.isEmpty ? "Drobo" : e.name) \(e.modell)"); Spacer(); Button("Hinzufügen") { m.hinzufuegen(e) } }.accessibilityElement(children: .combine)
                }
                HStack {
                    TextField("Name", text: $neuName)
                    TextField("Volume-Kennung", text: $neuKennung)
                    Button("Hinzufügen") {
                        let k = neuKennung.trimmingCharacters(in: .whitespaces)
                        guard !neuName.isEmpty, UUID(uuidString: k) != nil else { m.meldung = Meldung(titel: "Drobo", text: String(localized: "Name und eine gültige Volume-Kennung eingeben.")); return }
                        m.aendern(String(localized: "Drobo hinzufügen")) { $0.drobos.append(DroboEintrag(uuid: k, name: neuName)) }; neuName = ""; neuKennung = ""
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
        .frame(minWidth: Mass.einstellungenBreiteMin, minHeight: Mass.einstellungenBreiteMin)
        .onAppear { sicherungsort = m.einstellungen.sicherungOrt }
        .onChange(of: m.einstellungen.sicherungOrt) { _, n in sicherungsort = n }
        .sheet(isPresented: $anleitung) { SpotlightAnleitung() }
    }
}

struct MenueleistenInhalt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("DroboDraft · Frühe Alpha 0.1.0")
        if let a = m.aktuell {
            Text("\(a.eintrag.name): \(a.zustandText)")
            if let s = a.hw?.schwere { Label(s == .kritisch ? "Zustand: kritisch" : (s == .warnung ? "Zustand: Warnung" : "Zustand: in Ordnung"), systemImage: s == .ok ? "checkmark.circle" : (s == .warnung ? "exclamationmark.triangle" : "xmark.octagon")) }
            if m.liste.count > 1 {
                Picker("Drobo", selection: $m.auswahl) { ForEach(m.liste, id: \.eintrag.uuid) { Text($0.eintrag.name).tag($0.eintrag.uuid) } }
            }
            Divider()
            Button("Im Finder öffnen") { m.fuehreAus(.imFinder) }.disabled(!m.aktiv(.imFinder))
            Button("Aushängen") { m.fuehreAus(.aushaengen) }.disabled(!m.aktiv(.aushaengen))
        }
        Divider()
        Button("Fenster öffnen …") { openWindow(id: "haupt"); NSApp.activate(ignoringOtherApps: true) }
        SettingsLink { Text("Einstellungen …") }
        Divider()
        Button("DroboDraft beenden") { NSApp.terminate(nil) }
    }
}
