import DroboKern
import SwiftUI

/// Netzwerk-Drobo: alle virtuellen Festplatten (LUNs) in der Uebersicht, je LUN Einhaengen/Aushaengen/Formatieren, dazu "Alle einhaengen".
struct LunKarte: View {
    @EnvironmentObject var m: DroboModell
    let a: DroboAnsicht
    @Binding var rwFrage: Bool
    @State private var formatLun: Int?

    func name(_ l: LunEintrag) -> String { a.eintrag.netz?.luns?.first { $0.lun == l.lun }?.name ?? String(localized: "Volume \(l.lun + 1)") }

    var body: some View {
        Karte(titel: "Virtuelle Festplatten") {
            Text("Die Drobo stellt dem Mac mehrere virtuelle Festplatten (Volumes) zur Verfügung. Jede lässt sich einzeln einhängen.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button { m.alleLunsEinhaengen() } label: { Label("Alle einhängen", systemImage: "externaldrive.badge.plus") }
                    .disabled(m.arbeit != nil || !a.luns.contains { $0.hatDateisystem && a.lunEingehaengt[$0.lun] == nil })
                Button { m.alleLunsAushaengen() } label: { Label("Alle aushängen", systemImage: "eject") }.disabled(m.arbeit != nil || a.lunEingehaengt.isEmpty)
            }
            ForEach(a.luns, id: \.lun) { l in zeile(l) }
        }
        .sheet(item: Binding(get: { formatLun.map { FormatZiel(lun: $0) } }, set: { formatLun = $0?.lun })) { z in
            FormatBlatt(lun: z.lun, vorgabe: a.luns.first { $0.lun == z.lun }.map(name) ?? "DroboPro", groesse: a.luns.first { $0.lun == z.lun }?.groesse ?? 0)
        }
    }

    func zeile(_ l: LunEintrag) -> some View {
        let mount = a.lunEingehaengt[l.lun]
        let zustand = mount.map { $0 ? String(localized: "Eingehängt, nur lesen") : String(localized: "Eingehängt, schreiben") } ?? (l.hatDateisystem ? String(localized: "Nicht eingehängt") : String(localized: "Kein Dateisystem"))
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
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
                    Button("Zum Schreiben einhängen …") { m.schreibenLun = l.lun; rwFrage = true }
                } label: { Label("Einhängen", systemImage: "externaldrive.badge.plus") }.fixedSize().disabled(m.arbeit != nil)
            }
            Button { formatLun = l.lun } label: { Label("Formatieren …", systemImage: "trash") }
                .disabled(m.arbeit != nil || mount != nil)
                .help(mount != nil ? Text("Zum Formatieren zuerst aushängen.") : Text("Formatiert diese virtuelle Festplatte neu."))
        }
    }
}

struct FormatZiel: Identifiable { let lun: Int; var id: Int { lun } }

/// Bestaetigung vor dem Formatieren einer LUN. "Abbrechen" ist die Standardaktion; Formatieren hat kein Tastenkuerzel.
struct FormatBlatt: View {
    @EnvironmentObject var m: DroboModell
    @Environment(\.dismiss) private var dismiss
    let lun: Int
    let groesse: UInt64
    @State private var name: String
    init(lun: Int, vorgabe: String, groesse: UInt64) { self.lun = lun; self.groesse = groesse; _name = State(initialValue: vorgabe) }

    var gueltig: Bool { let n = name.trimmingCharacters(in: .whitespaces); return !n.isEmpty && !n.contains(":") && n.utf8.count <= 27 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Volume \(lun + 1) formatieren?").font(.title2).accessibilityAddTraits(.isHeader)
            Hinweis(symbol: "exclamationmark.triangle.fill", text: "Alle Daten dieser virtuellen Festplatte gehen verloren. Das lässt sich nicht rückgängig machen.", farbe: .red)
            Text("Größe der virtuellen Festplatte: \(groesseText(groesse)). Sie wird mit einem leeren Dateisystem (Mac OS Extended) neu angelegt.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            if !gueltig { Label("Der Name darf nicht leer sein, keinen Doppelpunkt enthalten und höchstens 27 Zeichen lang sein.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction)
                Button("Formatieren", role: .destructive) { dismiss(); m.lunFormatieren(lun, name: name.trimmingCharacters(in: .whitespaces)) }.disabled(!gueltig)
            }
        }.padding(24).frame(width: 520)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Drobo umbenennen").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Der Name gilt nur in dieser App.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { speichern() }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Speichern") { speichern() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 420)
    }
    func speichern() { m.umbenennen(uuid, name: name); dismiss() }
}
