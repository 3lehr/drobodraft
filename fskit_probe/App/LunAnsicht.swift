import DroboKern
import SwiftUI

/// Netzwerk-Drobo: alle virtuellen Festplatten (LUNs) in der Uebersicht, je LUN Einhaengen/Aushaengen/Formatieren, dazu "Alle einhaengen".
struct LunKarte: View {
    @EnvironmentObject var m: DroboModell
    let a: DroboAnsicht

    func name(_ l: LunEintrag) -> String { a.eintrag.netz?.luns?.first { $0.lun == l.lun }?.name ?? String(localized: "Volume \(l.lun + 1)") }

    var body: some View {
        Karte(titel: "Virtuelle Festplatten") {
            Text("Die Drobo stellt dem Mac mehrere virtuelle Festplatten (Volumes) zur Verfügung. Jede lässt sich einzeln einhängen.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { m.alleLunsEinhaengen() } label: { Label("Alle einhängen", systemImage: "externaldrive.badge.plus") }
                    .disabled(m.arbeit != nil || !a.luns.contains { $0.hatDateisystem && a.lunEingehaengt[$0.lun] == nil })
                Button { m.alleLunsAushaengen() } label: { Label("Alle aushängen", systemImage: "eject") }.disabled(m.arbeit != nil || a.lunEingehaengt.isEmpty)
            }
            if a.lunsGespeichert { Label("Stand vom letzten Kontakt", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
            ForEach(a.luns, id: \.lun) { l in zeile(l) }
        }
    }

    func zeile(_ l: LunEintrag) -> some View {
        let mount = a.lunEingehaengt[l.lun]
        let zustand = mount.map { $0 ? String(localized: "Eingehängt, nur lesen") : String(localized: "Eingehängt, schreiben") } ?? (l.hatDateisystem ? String(localized: "Nicht eingehängt") : String(localized: "Kein Dateisystem"))
        return HStack(alignment: .firstTextBaseline, spacing: Abstand.m) {
            VStack(alignment: .leading, spacing: Abstand.haar) {
                Text(l.hatDateisystem ? name(l) : String(localized: "Volume \(l.lun + 1)")).fontWeight(.semibold)
                Text("\(zustand), \(groesseText(l.partitionBytes ?? l.groesse))").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if mount != nil {
                Button { m.lunAushaengen(l.lun) } label: { Label("Aushängen", systemImage: "eject") }.disabled(m.arbeit != nil)
            } else if l.hatDateisystem {
                Menu {
                    Button("Einhängen (nur lesen)") { m.lunEinhaengen(l.lun, schreiben: false) }
                    Button("Zum Schreiben einhängen …") { m.schreibenLun = l.lun; m.blatt = .schreiben }
                } label: { Label("Einhängen", systemImage: "externaldrive.badge.plus") }.fixedSize().disabled(m.arbeit != nil)
            }
            Button { m.blatt = .format(l.lun) } label: { Label("Formatieren …", systemImage: "trash") }
                .disabled(m.arbeit != nil || mount != nil)
                .help(mount != nil ? Text("Zum Formatieren zuerst aushängen.") : Text("Formatiert diese virtuelle Festplatte neu."))
        }
    }
}

/// Bestaetigung vor dem Formatieren einer LUN (EIN Blatt, mit "Erprobt mit"). "Abbrechen" ist die Standardaktion; Formatieren hat kein Tastenkuerzel.
struct FormatBlatt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    let lun: Int
    @State private var name = ""
    @State private var tib = 0      // 0 = ganze virtuelle Festplatte, sonst Partitionsgroesse in TiB

    var eintrag: LunEintrag? { m.aktuell?.luns.first { $0.lun == lun } }
    var bisher: String { m.aktuell?.eintrag.netz?.luns?.first { $0.lun == lun }?.name ?? String(localized: "Volume \(lun + 1)") }
    var gueltig: Bool { let n = name.trimmingCharacters(in: .whitespaces); return !n.isEmpty && !n.contains(":") && n.utf8.count <= 27 }
    var freigegeben: Bool { m.erprobtErgebnis(.formatieren).istErprobt || m.blattGesichert }

    var body: some View {
        VStack(alignment: .leading, spacing: Abstand.l) {
            Text("Volume \(lun + 1) formatieren?").font(.title2).accessibilityAddTraits(.isHeader)
            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Alle Daten dieser virtuellen Festplatte gehen verloren. Das lässt sich nicht rückgängig machen.", farbe: .red)
            VStack(alignment: .leading, spacing: Abstand.xs) {
                Zeile(name: "Volume", wert: "\(lun + 1)")
                Zeile(name: "Bisheriger Name", wert: bisher)
                if let e = eintrag {
                    Zeile(name: "Größe der virtuellen Festplatte", wert: groesseText(e.groesse))
                    if let p = e.partitionBytes { Zeile(name: "Partition", wert: groesseText(p)) }
                }
            }
            Text("Die virtuelle Festplatte wird mit einem leeren Dateisystem (Mac OS Extended) neu angelegt.").foregroundStyle(.secondary)
            Picker("Partitionsgröße", selection: $tib) {
                Text("Ganze virtuelle Festplatte").tag(0)
                ForEach([2, 4, 8].filter { UInt64($0) << 40 < (eintrag?.groesse ?? 0) }, id: \.self) { Text("\($0) TiB").tag($0) }
            }
            Zeile(name: "Format", wert: "Mac OS Extended (HFS+)")
            Text("DroboDraft kann nur dieses Format einhängen; die Drobo erkennt freien Platz nur bei HFS+.").font(.callout).foregroundStyle(.secondary)
            Text("Die Schutzstufe (eine oder zwei Platten dürfen ausfallen) ist eine Einstellung der Drobo und lässt sich hier nicht ändern.").font(.callout).foregroundStyle(.secondary)
            Label("Formatieren läuft auf diesem Mac. Mac und Verbindung müssen bis zum Ende bestehen.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            ErprobtBlock(aktion: .formatieren, gesichert: $m.blattGesichert)
            TextField("Neuer Name", text: $name).textFieldStyle(.roundedBorder)
            if !gueltig { Label("Der Name darf nicht leer sein, keinen Doppelpunkt enthalten und höchstens 27 Zeichen lang sein.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            HStack(alignment: .top) {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                SperrKnopf(titel: "Formatieren", freigegeben: gueltig && freigegeben, rolle: .destructive) { m.formatBestaetigen(lun: lun, name: name, partitionBytes: tib == 0 ? nil : UInt64(tib) << 40) }
            }
        }
        .padding().frame(minWidth: Mass.blattMin, idealWidth: Mass.blattBreit)
        .onAppear { if name.isEmpty { name = bisher } }
    }
}

/// App-Name einer Drobo aendern (nur in der App gespeichert, nicht am Geraet).
struct UmbenennenBlatt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    let uuid: String
    @State private var name: String
    init(uuid: String, name: String) { self.uuid = uuid; _name = State(initialValue: name) }
    var body: some View {
        VStack(alignment: .leading, spacing: Abstand.l) {
            Text("Drobo umbenennen").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Der Name gilt nur in dieser App.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { speichern() }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") { speichern() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding().frame(minWidth: Mass.blattMin, idealWidth: Mass.blattSchmal)
    }
    func speichern() { m.umbenennen(uuid, name: name); dismiss() }
}
