import DroboKern
import SwiftUI
import UniformTypeIdentifiers

struct HauptAnsicht: View {
    @EnvironmentObject var m: DroboModell

    var body: some View {
        NavigationSplitView {
            Seitenleiste(abschnitt: $m.abschnitt)
                .navigationSplitViewColumnWidth(min: Mass.seitenleisteMin, ideal: Mass.seitenleisteIdeal)
        } detail: {
            Group {
                switch m.abschnitt ?? .uebersicht {
                case .uebersicht: UebersichtAnsicht()
                case .volume: VolumeAnsicht()
                case .tempo: TempoAnsicht()
                case .protokoll: ProtokollAnsicht()
                case .laufwerke: LaufwerkeAnsicht()
                case .finden: DrobosFindenAnsicht()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: Abstand.keiner) { Statusleiste() }
        .navigationTitle("DroboDraft")
        // Hoechstens EIN Blatt zugleich (Norm): alle Aktionen oeffnen es ueber m.blatt
        .sheet(item: $m.blatt, onDismiss: { m.schreibenLun = nil }) { b in
            switch b {
            case .schreiben: SchreibenBestaetigung()
            case .umbenennen(let u): UmbenennenBlatt(uuid: u, name: m.einstellungen.drobos.first { $0.uuid == u }?.name ?? "")
            case .anleitung: SpotlightAnleitung()
            case .restore: RestoreBestaetigung()
            case .format(let l): FormatBlatt(lun: l)
            }
        }
        .alert(item: $m.meldung) { Alert(title: Text(LocalizedStringKey($0.titel)), message: Text($0.text), dismissButton: .default(Text("OK"))) }
        .overlay(alignment: .top) { if let a = m.arbeit { Label("\(a) …", systemImage: "hourglass").padding(Abstand.s).background(.regularMaterial, in: Capsule()).padding(.top, Abstand.s) } }
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
            VStack(alignment: .leading, spacing: Abstand.s) {
                if dienstProblem {
                    zeile(String(localized: "Der Hilfsdienst ist nicht bereit (\(m.hilfsdienst)). Er hängt die Drobo ein. Wähle „Einrichten“ und bestätige in den Systemeinstellungen.")) { Button("Einrichten") { m.dienstRegistrieren() } }
                }
                if zugriffProblem {
                    zeile(String(localized: "Der Festplattenvollzugriff fehlt. Ohne ihn lässt sich die Drobo nicht einhängen. Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit.")) { Button("Anleitung …") { m.festplattenzugriffOeffnen() } }
                }
                if !m.modul.installiert {
                    zeile(String(localized: "Das Treibermodul ist nicht installiert. Ohne es lässt sich die Drobo nicht einhängen.")) { EmptyView() }
                } else if !m.modul.freigeschaltet {
                    zeile(String(localized: "Das Treibermodul ist nicht freigeschaltet. Schalte es in den Systemeinstellungen unter Allgemein, Anmeldeobjekte & Erweiterungen, Dateisystem-Erweiterungen ein.")) { EmptyView() }
                }
            }
            .padding(.horizontal).padding(.vertical, Abstand.s).frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityElement(children: .contain).accessibilityLabel("Hinweise zur Einrichtung")
        }
    }

    func zeile<B: View>(_ text: String, @ViewBuilder knopf: () -> B) -> some View {
        HStack(spacing: Abstand.s) {
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
    var body: some View {
        HStack {
            if a.eingehaengt {
                Button { m.aushaengen() } label: { Label("Aushängen", systemImage: "eject") }
                if a.nurlesen { Button { m.fuehreAus(.neuSchreiben) } label: { Label("Zum Schreiben neu", systemImage: "pencil") } }
            } else if !a.verbunden {
                Text(a.eintrag.netz != nil ? "Nicht erreichbar. Die Aktionen sind verfügbar, sobald die DroboPro im Netzwerk gefunden wird." : "Nicht angeschlossen. Die Aktionen sind verfügbar, sobald die Drobo angeschlossen ist.").font(.callout).foregroundStyle(.secondary)
            } else if a.verbunden {
                Button { m.einhaengen(schreiben: false) } label: { Label("Einhängen (nur lesen)", systemImage: "externaldrive.badge.plus") }
                Button { m.fuehreAus(.einhaengenSchreiben) } label: { Label("Zum Schreiben einhängen", systemImage: "pencil") }
            }
        }.disabled(m.arbeit != nil)
    }
}

struct VolumeAnsicht: View {
    @EnvironmentObject var m: DroboModell

    func waehlen(_ start: String?, _ titel: String) -> String? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = String(localized: "Wählen"); p.message = titel
        if let s = start { p.directoryURL = URL(fileURLWithPath: s) }
        return p.runModal() == .OK ? p.url?.path : nil
    }

    var body: some View {
        ScrollView {
            if let a = m.aktuell, a.eintrag.rolle == .arbeitsvolume {
                VStack(alignment: .leading, spacing: Abstand.l) {
                    Text(a.eintrag.name).font(.largeTitle).accessibilityAddTraits(.isHeader)
                    Karte(titel: "Zugriff") {
                        if a.eintrag.netz == nil { Zeile(name: "Freigabe", wert: a.freigabe == .schreiben ? String(localized: "Schreiben erlaubt") : (a.freigabe == .nurlesen ? String(localized: "nur lesen") : String(localized: "noch nicht eingerichtet"))) }
                        AktionsZeile(a: a)
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
                                Button(role: .destructive) { m.fuehreAus(.zurueckspielen) } label: { Label("Zurückspielen …", systemImage: "arrow.uturn.backward") }
                                    .disabled(m.restoreProbeFuer != m.restoreAuswahl || a.eingehaengt || m.arbeit != nil)
                            }
                        }
                    }
                    Karte(titel: "Ordner wegsichern") {
                        Text("Kopiert einen Ordner von der Drobo auf ein anderes Laufwerk. Nur lesend an der Drobo; bereits gesicherte, unveränderte Dateien werden übersprungen, jede Kopie wird per SHA-256 gegen das Original geprüft.").font(.callout).foregroundStyle(.secondary)
                        HStack { Text("Quelle:"); Text(m.wegQuelle.isEmpty ? String(localized: "nicht gewählt") : m.wegQuelle).lineLimit(1).truncationMode(.middle); Spacer()
                            Button("Wählen …") { if let p = waehlen(a.ort.isEmpty ? nil : a.ort, String(localized: "Quellordner auf der Drobo")) { m.wegQuelle = p } }.disabled(!a.eingehaengt) }
                        HStack { Text("Ziel:"); Text(m.wegZiel.isEmpty ? String(localized: "nicht gewählt") : m.wegZiel).lineLimit(1).truncationMode(.middle); Spacer()
                            Button("Wählen …") { if let p = waehlen(nil, String(localized: "Zielordner auf einem anderen Laufwerk")) { m.wegZiel = p } } }
                        Button { m.fuehreAus(.wegsichern) } label: { Label("Wegsichern", systemImage: "arrow.down.doc") }
                            .disabled(m.wegQuelle.isEmpty || m.wegZiel.isEmpty || !a.eingehaengt || m.arbeit != nil)
                        if !m.wegsichernBericht.isEmpty { Text(m.wegsichernBericht).font(.callout).textSelection(.enabled) }
                    }
                    }
                }.padding()
                .onAppear { if m.restoreAuswahl.isEmpty || !a.sicherungen.contains(m.restoreAuswahl) { m.restoreAuswahl = a.sicherungen.first ?? "" } }
            } else { Text("Für ein Time-Machine-Ziel gibt es hier nichts einzustellen.").padding() }
        }
    }
}

struct ProtokollAnsicht: View {
    @EnvironmentObject var m: DroboModell
    var body: some View {
        VStack(alignment: .leading) {
            Text("Protokoll").font(.largeTitle).accessibilityAddTraits(.isHeader).padding([.top, .horizontal], 20)
            if m.protokoll.isEmpty { Text("Noch keine Einträge.").padding().foregroundStyle(.secondary) }
            List(Array(m.protokoll.reversed().enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading) { Text(e.text); Text(zeitLesbar(e.zeit)).font(.caption).foregroundStyle(.secondary) }.accessibilityElement(children: .combine)
            }
        }
    }
}


/// Bestätigung vor jedem Schreib-Einhängen. "Abbrechen" ist die Standardaktion (Return/Escape), das Schreiben hat keine Tastenkürzel.
/// Volles Blatt mit 15-s-Sperre beim ersten Mal je Drobo und bei jeder Änderung (Firmware, Anschluss, Schreibweg, unsauberes Ende) bzw. bei nicht erprobter Kombination; sonst eine Zeile.
struct SchreibenBestaetigung: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    var art: BlattArt { m.blattArtOffen }

    func grund(_ g: VollGrund) -> LocalizedStringKey? {
        switch g {
        case .erstmals: return "Zum ersten Mal mit dieser Drobo."
        case .firmware: return "Die Firmware der Drobo hat sich seit dem letzten Mal geändert."
        case .anschluss: return "Der Anschluss der Drobo hat sich seit dem letzten Mal geändert."
        case .schreibweg: return "DroboDraft hat den Weg zum Schreiben seit dem letzten Mal geändert."
        case .unsauber: return "Die letzte Schreibsitzung endete unsauber."
        case .nichtErprobt, .formatieren: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Abstand.l) {
            Text("Zum Schreiben einhängen?").font(.title2).accessibilityAddTraits(.isHeader)
            if case .voll(let g) = art {
                Text("Vorher wird eine Sicherung der Verwaltungsdaten des Laufwerks angelegt. Ohne gelungene Sicherung wird nicht zum Schreiben eingehängt.")
                if let t = grund(g) { Text(t).foregroundStyle(.secondary) }
                ErprobtBlock(aktion: .schreiben, gesichert: $m.blattGesichert)
            } else {
                Label { Text("Entspricht der erprobten Kombination · Die Sicherung der Verwaltungsdaten wird vorher angelegt.") } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green) }
                    .accessibilityElement(children: .combine)
            }
            if m.spotlightHinweisNoetig { Hinweis(symbol: "magnifyingglass", text: "Spotlight ist für die Drobo noch nicht ausgeschlossen (empfohlen, siehe Anleitung in den Einstellungen).") }
            if m.physischKnapp, let k = m.aktuell?.hw?.kapazitaet {
                Hinweis(symbol: "externaldrive.badge.exclamationmark", text: "Die Drobo ist physisch fast voll: nur noch \(groesseText(k.frei)) frei (unter 5 %). Schreiben auf eine fast volle Drobo kann scheitern oder sie verlangsamen. Schaffe zuerst Platz oder setze größere Festplatten ein.", farbe: .red)
            }
            if m.einstellungen.sicherungOrt.isEmpty {
                Hinweis(symbol: "externaldrive.badge.exclamationmark", text: "Schreiben ist gesperrt, bis ein Sicherungsort gewählt ist: ein Ordner auf einem anderen Laufwerk als dem Startvolume und der Drobo, mit einigen GB Platz.", farbe: .red)
                Button("Sicherungsort wählen …") { m.sicherungsOrtWaehlen() }
            } else {
                Text("Sicherungsort: \(m.einstellungen.sicherungOrt)").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                SperrKnopf(titel: "Zum Schreiben einhängen", freigegeben: m.schreibenFreigegeben, rolle: nil) { m.schreibenBestaetigen() }
            }
        }
        .padding().frame(minWidth: Mass.blattMin, idealWidth: Mass.blatt)
    }
}

/// Bestätigen-Knopf mit Countdown im Titel ("Einhängen (15)"), bis die Sperre abgelaufen ist. VoiceOver: Ansage bei 10 s und bei 0, nicht jede Sekunde.
struct SperrKnopf: View {
    @EnvironmentObject var m: DroboModell
    let titel: LocalizedStringKey
    let freigegeben: Bool
    let rolle: ButtonRole?
    let aktion: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let rest = m.sperreRest()
            VStack(alignment: .trailing, spacing: Abstand.xs) {
                Button(role: rolle, action: aktion) { rest > 0 ? Text("\(Text(titel)) (\(rest))") : Text(titel) }
                    .disabled(rest > 0 || !freigegeben)
                    .accessibilityHint(rest > 0 ? Text("Gesperrt, noch \(rest) Sekunden.") : Text(""))
                if rest > 0 { Text("Bestätigen wird in \(rest) s frei. Abbrechen geht jederzeit.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task {
            guard m.blattDauer > 0 else { return }
            for ziel in [10, 0] where m.sperreRest() > ziel {
                while m.sperreRest() > ziel { try? await Task.sleep(for: .milliseconds(250)); if Task.isCancelled { return } }
                AccessibilityNotification.Announcement(ziel > 0 ? String(localized: "Noch \(ziel) Sekunden, bis Bestätigen möglich ist.") : String(localized: "Bestätigen ist jetzt möglich.")).post()
            }
        }
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
        VStack(alignment: .leading, spacing: Abstand.s) {
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
        VStack(alignment: .leading, spacing: Abstand.l) {
            Text("Sicherung wirklich zurückspielen?").font(.title2).accessibilityAddTraits(.isHeader)
            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Alles, was seit dieser Sicherung auf die Drobo geschrieben wurde, geht verloren. Das lässt sich nicht rückgängig machen.", farbe: .red)
            Text(m.restoreProbeText).font(.callout.monospaced())
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                Button("Zurückspielen", role: .destructive) { dismiss(); m.restoreAusfuehren() }
            }
        }.padding().frame(minWidth: Mass.blattMin, idealWidth: Mass.blattBreit)
    }
}
