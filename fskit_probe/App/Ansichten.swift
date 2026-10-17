import DroboKern
import SwiftUI
import UniformTypeIdentifiers

enum Abschnitt: String, CaseIterable, Identifiable {
    case uebersicht = "Übersicht", volume = "Volume", tempo = "Tempo", protokoll = "Protokoll", laufwerke = "Laufwerke"
    var id: String { rawValue }
    var symbol: String { switch self { case .uebersicht: return "gauge.with.dots.needle.33percent"; case .volume: return "externaldrive"; case .tempo: return "speedometer"; case .protokoll: return "list.bullet.rectangle"; case .laufwerke: return "internaldrive" } }
}

struct HauptAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @State private var abschnitt: Abschnitt? = .uebersicht
    @State private var rwFrage = false
    @State private var anleitung = false
    @State private var netzBlatt = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Drobo") {
                    Button { m.drobosSuchen() } label: { Label(m.sucheLaeuft ? "Suche läuft …" : "Drobos suchen", systemImage: "magnifyingglass") }
                        .disabled(m.sucheLaeuft)
                        .accessibilityLabel("Drobos suchen, USB und lokales Netzwerk")
                    if let i = m.sucheInfo { Text(i).font(.callout).foregroundStyle(.secondary) }
                    if m.liste.isEmpty { Text("Keine Drobo eingerichtet").foregroundStyle(.secondary) }
                    ForEach(m.liste, id: \.eintrag.uuid) { d in
                        Button { m.auswahl = d.eintrag.uuid } label: {
                            HStack {
                                ZustandPunkt(stufe: d.stufe)
                                VStack(alignment: .leading, spacing: 1) { Text(d.eintrag.name); Text(d.zustandText).font(.caption).foregroundStyle(.secondary) }
                                Spacer(); if m.auswahl == d.eintrag.uuid { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(d.eintrag.name), \(d.zustandText)")
                        .accessibilityAddTraits(m.auswahl == d.eintrag.uuid ? [.isSelected, .isButton] : .isButton)
                    }
                    ForEach(m.erkannte, id: \.uuid) { e in
                        HStack { Text(e.name.isEmpty ? "Drobo" : e.name); Spacer(); Button("Hinzufügen") { m.hinzufuegen(e) } }
                            .accessibilityElement(children: .combine)
                    }
                    ForEach(m.lanErkannte, id: \.host) { d in
                        HStack { Label("Im Netzwerk gefunden: DroboPro (\(d.host))", systemImage: "network"); Spacer(); Button("Hinzufügen") { m.lanHinzufuegen(d) } }
                            .accessibilityElement(children: .combine)
                    }
                    Button { netzBlatt = true } label: { Label("Per Adresse hinzufügen …", systemImage: "plus") }.font(.callout)
                }
                Section("Ansicht") {
                    ForEach(Abschnitt.allCases) { a in
                        let gewaehlt = (abschnitt ?? .uebersicht) == a
                        Button { abschnitt = a } label: {
                            HStack { Label(LocalizedStringKey(a.rawValue), systemImage: a.symbol).fontWeight(gewaehlt ? .bold : .regular); Spacer() }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(gewaehlt ? Color.accentColor.opacity(0.28) : Color.clear)
                        .accessibilityAddTraits(gewaehlt ? [.isSelected, .isButton] : .isButton)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Group {
                switch abschnitt ?? .uebersicht {
                case .uebersicht: UebersichtAnsicht(rwFrage: $rwFrage, anleitung: $anleitung)
                case .volume: VolumeAnsicht(rwFrage: $rwFrage)
                case .tempo: TempoAnsicht()
                case .protokoll: ProtokollAnsicht()
                case .laufwerke: LaufwerkeAnsicht()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Statusleiste() }
        .navigationTitle("DroboDraft")
        .sheet(isPresented: $anleitung) { SpotlightAnleitung() }
        .sheet(isPresented: $netzBlatt) { NetzHinzufuegenBlatt() }
        .onReceive(NotificationCenter.default.publisher(for: .schreibenFrage)) { _ in rwFrage = true }
        .sheet(isPresented: $rwFrage) { SchreibenBestaetigung() }
        .alert(item: $m.meldung) { Alert(title: Text(LocalizedStringKey($0.titel)), message: Text($0.text), dismissButton: .default(Text("OK"))) }
        .overlay(alignment: .top) { if let a = m.arbeit { Label("\(a) …", systemImage: "hourglass").padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8) } }
    }
}

struct Statusleiste: View {
    @EnvironmentObject var m: DroboModell
    var body: some View {
        HStack(spacing: 18) {
            StatusChip(name: String(localized: "Hilfsdienst"), wert: m.hilfsdienst, gut: m.hilfsdienst == String(localized: "bereit"))
            if m.hilfsdienst != String(localized: "bereit") { Button("Einrichten") { m.dienstRegistrieren() }.font(.callout) }
            StatusChip(name: String(localized: "Festplattenzugriff"), wert: m.festplattenzugriff, gut: m.festplattenzugriff == String(localized: "in Ordnung"))
            if m.festplattenzugriff == String(localized: "fehlt") { Button("Anleitung …") { m.festplattenzugriffOeffnen() }.font(.callout) }
            StatusChip(name: String(localized: "Treibermodul"), wert: !m.modul.installiert ? String(localized: "nicht installiert") : (m.modul.freigeschaltet ? String(localized: "bereit") : String(localized: "nicht freigeschaltet")), gut: m.modul.freigeschaltet)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain).accessibilityLabel("Statusleiste")
    }
}

struct UebersichtAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @Binding var rwFrage: Bool
    @Binding var anleitung: Bool

    var body: some View {
        ScrollView {
            if let a = m.aktuell {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ZustandPunkt(stufe: a.stufe)
                        Text(a.eintrag.name).font(.largeTitle).accessibilityAddTraits(.isHeader)
                        Spacer()
                        FruehAlphaAbzeichen()
                    }
                    Text(a.zustandText).font(.title3).foregroundStyle(.secondary)
                    if a.eintrag.netz != nil && !a.verbunden {
                        Hinweis(symbol: "wifi.exclamationmark", text: "Die DroboPro ist nicht erreichbar. Prüfen Sie, ob sie eingeschaltet und mit dem Netzwerk verbunden ist, und wählen Sie links „Drobos suchen“.", farbe: .orange)
                    }
                    if a.eintrag.rolle == .timemachine {
                        Hinweis(symbol: "clock.arrow.circlepath", text: "Dieses Laufwerk ist als Time-Machine-Ziel eingetragen. Die App zeigt nur den Anschluss; macOS verwaltet das Laufwerk und die App hängt es nie selbst ein.", farbe: .blue)
                    } else {
                        if m.festplattenzugriff == String(localized: "fehlt") && a.eintrag.netz == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Hinweis(symbol: "lock.trianglebadge.exclamationmark", text: "Der Hilfsdienst darf nicht auf das Laufwerk zugreifen. Ohne Festplattenvollzugriff lässt sich die Drobo nicht einhängen.", farbe: .red)
                                Button("Systemeinstellungen öffnen") { m.festplattenzugriffOeffnen() }
                            }
                        }
                        if let g = a.merker.offenePruefung {
                            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Vor dem nächsten Einhängen wird geprüft: \(g)", farbe: .red)
                        }
                        Karte(titel: "Belegung") {
                            let vol: (belegt: UInt64, gesamt: UInt64, stand: String?)? = a.eingehaengt && a.gesamt > 0 ? (a.belegt, a.gesamt, nil) : a.belegungVH.map { ($0.belegt, $0.gesamt, $0.zeit) }
                            if let v = vol {
                                Text("Volume (laut Dateisystem)").font(.subheadline).foregroundStyle(.secondary)
                                BelegungsBalken(belegt: v.belegt, gesamt: v.gesamt, stand: v.stand)
                            } else { Text("Die Belegung wird gelesen, sobald der Festplattenzugriff in Ordnung ist.").foregroundStyle(.secondary) }
                            if let k = a.hw?.kapazitaet, k.gesamtGeschuetzt > 0 {
                                Divider()
                                Text("Physisch (laut Drobo)").font(.subheadline).foregroundStyle(.secondary)
                                BelegungsBalken(belegt: k.benutzt, gesamt: k.gesamtGeschuetzt, stand: nil, warnung: warnFarbe(k, a))
                                Text("Physisch frei: \(groesseText(k.frei)) (\(Int((k.freiAnteil * 100).rounded())) %)").font(.callout)
                                if let v = vol, v.gesamt > v.belegt, k.frei < v.gesamt - v.belegt {
                                    Hinweis(symbol: "exclamationmark.triangle.fill", text: "Die Drobo hat physisch weniger Platz frei, als das Volume anzeigt. Maßgeblich ist der physische Wert: Die Drobo meldet dem Mac mehr Speicher, als die Festplatten tatsächlich fassen.")
                                }
                            }
                        }
                        Karte(titel: "Einhängung") {
                            if let nz = a.eintrag.netz { Zeile(name: "Adresse", wert: nz.host) }
                            if a.eingehaengt {
                                Zeile(name: "Ort", wert: a.ort)
                                Button { m.imFinderOeffnen() } label: { Label("Im Finder öffnen", systemImage: "folder") }.keyboardShortcut("o", modifiers: .command)
                                Zeile(name: "Treiber", wert: "\(a.treiber) · " + (a.nurlesen ? String(localized: "nur lesen") : String(localized: "schreiben")))
                            } else { Text("Nicht eingehängt.").foregroundStyle(.secondary) }
                            if let t = m.tempo.last(where: { $0.uuid == a.eintrag.uuid }) {
                                Zeile(name: "Tempo zuletzt", wert: String(format: "%.0f MB/s (%@)", t.mbProSekunde, t.art == "lesen" ? String(localized: "lesen") : String(localized: "schreiben")))
                            }
                            AktionsZeile(a: a, rwFrage: $rwFrage)
                        }
                        if let p = a.merker.letztePruefung {
                            Karte(titel: "Letzte Prüfung") {
                                Label(p.ok ? "In Ordnung" : "Auffälligkeiten", systemImage: p.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill").foregroundStyle(p.ok ? Color.green : Color.red)
                                if !p.ok { Text(p.probleme.joined(separator: "\n")).font(.callout) }
                                Text(zeitLesbar(p.zeit)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if m.spotlightHinweisNoetig {
                            VStack(alignment: .leading, spacing: 8) {
                                Hinweis(symbol: "magnifyingglass", text: "Spotlight ist für die Drobo nicht ausgeschlossen. Beim Schreiben bremst das und verändert das Laufwerk. Der Ausschluss ist freiwillig.")
                                Button("Anleitung") { anleitung = true }
                            }
                        }
                    }
                }.padding(20)
            } else { Text("Keine Drobo eingerichtet. Eine angeschlossene Drobo erscheint links zum Hinzufügen; weitere Drobos über die Einstellungen (⌘,).").padding(20) }
        }
    }
}

/// Warnfarbe des physischen Fuellstands: Schwellen der Drobo (Seite 30, DroboPro gelb 85 / rot 95 Prozent belegt), sonst die festen 90 / 95 Prozent.
func warnFarbe(_ k: DroboKapazitaet, _ a: DroboAnsicht) -> Color? {
    let belegt = 1 - k.freiAnteil
    if let n = a.netz { return belegt * 100 >= Double(n.rotProzent) ? .red : (belegt * 100 >= Double(n.gelbProzent) ? .orange : nil) }
    return k.freiAnteil < 0.05 ? .red : (k.freiAnteil < 0.10 ? .orange : nil)
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
