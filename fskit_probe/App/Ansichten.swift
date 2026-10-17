import DroboKern
import SwiftUI
import UniformTypeIdentifiers

struct HauptAnsicht: View {
    @EnvironmentObject var m: DroboModell
    #if DEBUG
    @State private var abschnitt: Abschnitt? = DemoDaten.seite ?? .uebersicht
    #else
    @State private var abschnitt: Abschnitt? = .uebersicht
    #endif
    @State private var rwFrage = false
    @State private var anleitung = false

    var body: some View {
        NavigationSplitView {
            Seitenleiste(abschnitt: $abschnitt)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            Group {
                switch abschnitt ?? .uebersicht {
                case .uebersicht: UebersichtAnsicht(rwFrage: $rwFrage, anleitung: $anleitung, finden: { abschnitt = .finden })
                case .volume: VolumeAnsicht(rwFrage: $rwFrage)
                case .tempo: TempoAnsicht()
                case .protokoll: ProtokollAnsicht()
                case .laufwerke: LaufwerkeAnsicht()
                case .finden: DrobosFindenAnsicht()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Statusleiste() }
        .navigationTitle("DroboDraft")
        .sheet(isPresented: $anleitung) { SpotlightAnleitung() }
        .onReceive(NotificationCenter.default.publisher(for: .schreibenFrage)) { _ in rwFrage = true }
        .sheet(isPresented: $rwFrage) { SchreibenBestaetigung() }
        .alert(item: $m.meldung) { Alert(title: Text(LocalizedStringKey($0.titel)), message: Text($0.text), dismissButton: .default(Text("OK"))) }
        .overlay(alignment: .top) { if let a = m.arbeit { Label("\(a) …", systemImage: "hourglass").padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8) } }
    }
}

/// Nur bei einem Problem sichtbar, jeweils mit Anleitung. Laeuft alles, gibt es keine Leiste (keine Entwicklerinfo im Normalbetrieb).
struct Statusleiste: View {
    @EnvironmentObject var m: DroboModell
    var body: some View {
        let bereit = String(localized: "bereit")
        let dienstProblem = m.hilfsdienst != bereit && m.hilfsdienst != String(localized: "unbekannt")
        let zugriffProblem = m.festplattenzugriff == String(localized: "fehlt")
        let modulProblem = !m.modul.installiert || !m.modul.freigeschaltet
        if dienstProblem || zugriffProblem || modulProblem {
            VStack(alignment: .leading, spacing: 6) {
                if dienstProblem {
                    zeile(String(localized: "Der Hilfsdienst ist nicht bereit (\(m.hilfsdienst)). Er hängt die Drobo ein. Wählen Sie „Einrichten“ und bestätigen Sie in den Systemeinstellungen.")) { Button("Einrichten") { m.dienstRegistrieren() } }
                }
                if zugriffProblem {
                    zeile(String(localized: "Der Festplattenvollzugriff fehlt. Ohne ihn lässt sich die Drobo nicht einhängen. Erlauben Sie ihn in den Systemeinstellungen unter Datenschutz & Sicherheit.")) { Button("Anleitung …") { m.festplattenzugriffOeffnen() } }
                }
                if !m.modul.installiert {
                    zeile(String(localized: "Das Treibermodul ist nicht installiert. Ohne es lässt sich die Drobo nicht einhängen.")) { EmptyView() }
                } else if !m.modul.freigeschaltet {
                    zeile(String(localized: "Das Treibermodul ist nicht freigeschaltet. Schalten Sie es in den Systemeinstellungen unter Allgemein, Anmeldeobjekte & Erweiterungen, Dateisystem-Erweiterungen ein.")) { EmptyView() }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .contain).accessibilityLabel("Hinweise zur Einrichtung")
        }
    }

    func zeile<B: View>(_ text: String, @ViewBuilder knopf: () -> B) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            knopf().font(.callout)
        }.accessibilityElement(children: .contain)
    }
}

/// Aushaengen / Zum Schreiben neu: gleiche Knoepfe in Uebersicht und Volume.
struct AktionsZeile: View {
    @EnvironmentObject var m: DroboModell
    let a: DroboAnsicht
    @Binding var rwFrage: Bool
    var body: some View {
        HStack {
            if a.eingehaengt {
                Button { m.aushaengen() } label: { Label("Aushängen", systemImage: "eject") }.keyboardShortcut("e", modifiers: .command)
                if a.nurlesen { Button { rwFrage = true } label: { Label("Zum Schreiben neu", systemImage: "pencil") } }
            } else if !a.verbunden {
                Text(a.eintrag.netz != nil ? "Nicht erreichbar. Die Aktionen sind verfügbar, sobald die DroboPro im Netzwerk gefunden wird." : "Nicht angeschlossen. Die Aktionen sind verfügbar, sobald die Drobo angeschlossen ist.").font(.callout).foregroundStyle(.secondary)
            } else if a.verbunden {
                Button { m.einhaengen(schreiben: false) } label: { Label("Einhängen (nur lesen)", systemImage: "externaldrive.badge.plus") }
                Button { rwFrage = true } label: { Label("Zum Schreiben einhängen", systemImage: "pencil") }
            }
        }.disabled(m.arbeit != nil)
    }
}

struct VolumeAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @Binding var rwFrage: Bool
    @State private var quelle = ""
    @State private var ziel = ""
    @State private var restoreFrage = false

    func waehlen(_ start: String?, _ titel: String) -> String? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = String(localized: "Wählen"); p.message = titel
        if let s = start { p.directoryURL = URL(fileURLWithPath: s) }
        return p.runModal() == .OK ? p.url?.path : nil
    }

    var body: some View {
        ScrollView {
            if let a = m.aktuell, a.eintrag.rolle == .arbeitsvolume {
                VStack(alignment: .leading, spacing: 14) {
                    Text(a.eintrag.name).font(.largeTitle).accessibilityAddTraits(.isHeader)
                    Karte(titel: "Zugriff") {
                        if a.eintrag.netz == nil { Zeile(name: "Freigabe", wert: a.freigabe == .schreiben ? String(localized: "Schreiben erlaubt") : (a.freigabe == .nurlesen ? String(localized: "nur lesen") : String(localized: "noch nicht eingerichtet"))) }
                        AktionsZeile(a: a, rwFrage: $rwFrage)
                        if a.eintrag.netz == nil { Button { m.zugriffPruefen() } label: { Label("Festplattenzugriff prüfen", systemImage: "checkmark.shield") }.disabled(!a.verbunden || a.eingehaengt || m.arbeit != nil) }
                    }
                    Karte(titel: "Sicherungen der Verwaltungsdaten") {
                        Text("Vor jedem Einhängen zum Schreiben wird automatisch gesichert. Aufbewahrt werden \(m.einstellungen.sicherungAnzahl) Sicherungen in \(m.einstellungen.sicherungOrt.isEmpty ? String(localized: "(noch kein Ort gewählt)") : m.einstellungen.sicherungOrt).").font(.callout).foregroundStyle(.secondary)
                        if a.sicherungen.isEmpty { Text("Noch keine Sicherung.") }
                        ForEach(a.sicherungen, id: \.self) { Text(sicherungsZeit($0)).font(.callout.monospacedDigit()) }
                        if a.eintrag.netz == nil { Button { m.pruefen() } label: { Label("Jetzt prüfen", systemImage: "stethoscope") }.disabled(!a.verbunden || a.eingehaengt || m.arbeit != nil) }
                    }
                    if a.eintrag.netz != nil {
                        Hinweis(symbol: "info.circle", text: "Prüfen, Zurückspielen und Wegsichern gibt es für Netzwerk-Drobos noch nicht. Vor dem Einhängen zum Schreiben wird die Sicherung der Verwaltungsdaten angelegt.", farbe: .blue)
                    } else {
                    Karte(titel: "Sicherung zurückspielen") {
                        Text("Stellt die gesicherten Verwaltungsdaten wieder her. Nur bei ausgehängtem Laufwerk. Zuerst gibt es einen Probelauf, der nichts schreibt.").font(.callout).foregroundStyle(.secondary)
                        if a.sicherungen.isEmpty { Text("Noch keine Sicherung.") } else {
                            Picker("Sicherung", selection: $m.restoreAuswahl) {
                                ForEach(a.sicherungen, id: \.self) { Text(sicherungsZeit($0)).tag($0) }
                            }
                            Button { m.restoreProbe() } label: { Label("Probelauf", systemImage: "doc.text.magnifyingglass") }
                                .disabled(m.restoreAuswahl.isEmpty || !a.verbunden || a.eingehaengt || m.arbeit != nil)
                            if !m.restoreProbeText.isEmpty {
                                Text(m.restoreProbeText).font(.callout.monospaced()).textSelection(.enabled)
                                Button(role: .destructive) { restoreFrage = true } label: { Label("Zurückspielen …", systemImage: "arrow.uturn.backward") }
                                    .disabled(m.restoreProbeFuer != m.restoreAuswahl || a.eingehaengt || m.arbeit != nil)
                            }
                        }
                    }
                    Karte(titel: "Ordner wegsichern") {
                        Text("Kopiert einen Ordner von der Drobo auf ein anderes Laufwerk. Nur lesend an der Drobo; bereits gesicherte, unveränderte Dateien werden übersprungen, jede Kopie wird per SHA-256 gegen das Original geprüft.").font(.callout).foregroundStyle(.secondary)
                        HStack { Text("Quelle:"); Text(quelle.isEmpty ? String(localized: "nicht gewählt") : quelle).lineLimit(1).truncationMode(.middle); Spacer()
                            Button("Wählen …") { if let p = waehlen(a.ort.isEmpty ? nil : a.ort, String(localized: "Quellordner auf der Drobo")) { quelle = p } }.disabled(!a.eingehaengt) }
                        HStack { Text("Ziel:"); Text(ziel.isEmpty ? String(localized: "nicht gewählt") : ziel).lineLimit(1).truncationMode(.middle); Spacer()
                            Button("Wählen …") { if let p = waehlen(nil, String(localized: "Zielordner auf einem anderen Laufwerk")) { ziel = p } } }
                        Button { m.wegsichern(quelle: quelle, ziel: ziel) } label: { Label("Wegsichern", systemImage: "arrow.down.doc") }
                            .disabled(quelle.isEmpty || ziel.isEmpty || !a.eingehaengt || m.arbeit != nil)
                        if !m.wegsichernBericht.isEmpty { Text(m.wegsichernBericht).font(.callout).textSelection(.enabled) }
                    }
                    }
                }.padding(20)
                .onAppear { if m.restoreAuswahl.isEmpty || !a.sicherungen.contains(m.restoreAuswahl) { m.restoreAuswahl = a.sicherungen.first ?? "" } }
                .sheet(isPresented: $restoreFrage) { RestoreBestaetigung() }
            } else { Text("Für ein Time-Machine-Ziel gibt es hier nichts einzustellen.").padding(20) }
        }
    }
}

struct ProtokollAnsicht: View {
    @EnvironmentObject var m: DroboModell
    var body: some View {
        VStack(alignment: .leading) {
            Text("Protokoll").font(.largeTitle).accessibilityAddTraits(.isHeader).padding([.top, .horizontal], 20)
            if m.protokoll.isEmpty { Text("Noch keine Einträge.").padding(20).foregroundStyle(.secondary) }
            List(Array(m.protokoll.reversed().enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading) { Text(e.text); Text(zeitLesbar(e.zeit)).font(.caption).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
            }
        }
    }
}


/// Bestätigung vor jedem Schreib-Einhängen. "Abbrechen" ist die Standardaktion (Return/Escape), das Schreiben hat keine Tastenkürzel.
struct SchreibenBestaetigung: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Zum Schreiben einhängen?").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Vorher wird eine Sicherung der Verwaltungsdaten des Laufwerks angelegt. Ohne gelungene Sicherung wird nicht zum Schreiben eingehängt.")
            if m.spotlightHinweisNoetig { Hinweis(symbol: "magnifyingglass", text: "Spotlight ist für die Drobo noch nicht ausgeschlossen (empfohlen, siehe Anleitung in den Einstellungen).") }
            if m.physischKnapp, let k = m.aktuell?.hw?.kapazitaet {
                Hinweis(symbol: "externaldrive.badge.exclamationmark", text: "Die Drobo ist physisch fast voll: nur noch \(groesseText(k.frei)) frei (unter 5 %). Schreiben auf eine fast volle Drobo kann scheitern oder sie verlangsamen. Schaffen Sie zuerst Platz oder setzen Sie größere Festplatten ein.", farbe: .red)
            }
            if m.einstellungen.sicherungOrt.isEmpty {
                Hinweis(symbol: "externaldrive.badge.exclamationmark", text: "Schreiben ist gesperrt, bis ein Sicherungsort gewählt ist: ein Ordner auf einem anderen Laufwerk als dem Startvolume und der Drobo, mit einigen GB Platz.", farbe: .red)
                Button("Sicherungsort wählen …") { m.sicherungsOrtWaehlen() }
            } else {
                Text("Sicherungsort: \(m.einstellungen.sicherungOrt)").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                Button("Zum Schreiben einhängen") {
                    dismiss()
                    if m.aktuell?.eingehaengt == true { m.neuZumSchreiben() } else { m.einhaengen(schreiben: true) }
                }.disabled(m.einstellungen.sicherungOrt.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}

func sicherungsZeit(_ ordner: String) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
    guard let d = f.date(from: ordner.components(separatedBy: "_").last ?? "") else { return ordner }
    return d.formatted(date: .abbreviated, time: .shortened)
}

struct BelegungsBalken: View {
    let belegt: UInt64, gesamt: UInt64, stand: String?
    var warnung: Color?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(belegt), total: Double(max(gesamt, 1))) { Text("Belegt") }
                .tint(warnung)
                .accessibilityValue("\(groesseText(belegt)) / \(groesseText(gesamt))")
            Text("\(groesseText(belegt)) von \(groesseText(gesamt)) belegt").font(.callout).foregroundStyle(.secondary)
            if let s = stand { Text("Stand \(zeitLesbar(s)), aus den Verwaltungsdaten des Laufwerks").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Zweite, ausdrückliche Bestätigung. Abbrechen ist die Standardaktion; das Zurückspielen hat kein Tastenkürzel.
struct RestoreBestaetigung: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sicherung wirklich zurückspielen?").font(.title2).accessibilityAddTraits(.isHeader)
            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Alles, was seit dieser Sicherung auf die Drobo geschrieben wurde, geht verloren. Das lässt sich nicht rückgängig machen.", farbe: .red)
            Text(m.restoreProbeText).font(.callout.monospaced())
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                Button("Zurückspielen", role: .destructive) { dismiss(); m.restoreAusfuehren() }
            }
        }.padding(24).frame(width: 520)
    }
}
