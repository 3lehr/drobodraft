import DroboKern
import SwiftUI

/// Zustandspunkt: Farbe UND Symbol UND (daneben) Text (Farbe allein traegt keine Information, WCAG 1.4.1). Ein Problem der Drobo selbst geht vor dem Verbindungszustand.
struct ZustandPunkt: View {
    let stufe: DroboAnsicht.Stufe
    var gesamt: Gesamtzustand?
    var symbol: String {
        if let g = gesamt, g.stufe != .ok { return g.symbol }
        switch stufe { case .aus: return "circle"; case .bereit: return "link.circle.fill"; case .lesen: return "lock.circle.fill"; case .schreiben: return "pencil.circle.fill"; case .warnung: return "exclamationmark.triangle.fill" }
    }
    var farbe: Color {
        if let g = gesamt, g.stufe != .ok { return g.farbe }
        switch stufe { case .aus: return .secondary; case .bereit: return .blue; case .lesen: return .green; case .schreiben: return .orange; case .warnung: return .red }
    }
    var body: some View { Image(systemName: symbol).foregroundStyle(farbe).imageScale(.large).accessibilityHidden(true) }
}

/// Gemeinsame Karte (Gruppe mit Titel); alle Ansichten bauen daraus.
struct Karte<Inhalt: View>: View {
    let titel: LocalizedStringKey
    @ViewBuilder var inhalt: () -> Inhalt
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titel).font(.headline).accessibilityAddTraits(.isHeader)
            inhalt()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

/// Zeile "Beschriftung  Wert" fuer VoiceOver als ein Element.
struct Zeile: View {
    let name: LocalizedStringKey
    let wert: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(wert).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct Hinweis: View {
    let symbol: String
    let text: LocalizedStringKey
    var farbe: Color = .orange
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(farbe) }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(farbe.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

func groesseText(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

/// Kennzeichnung "Frühe Alpha": Text + Symbol (nicht nur Farbe).
struct FruehAlphaAbzeichen: View {
    var body: some View {
        Label("Frühe Alpha", systemImage: "hammer.fill").font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
            .accessibilityLabel("Frühe Alpha, Version 0.1.0")
    }
}

struct SpotlightAnleitung: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spotlight und Time Machine für die Drobo ausschließen").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Beim Schreiben legt Spotlight eigene Dateien auf der Drobo an und liest sie dauernd. Das bremst und verändert das Laufwerk. Der Ausschluss ist freiwillig; die App ändert dazu nichts an den Systemeinstellungen.")
            Text("1. Systemeinstellungen öffnen, Siri & Spotlight, Spotlight-Datenschutz.")
            Text("2. Mit dem Plus-Knopf den Einhängeort der Drobo hinzufügen (Standard: /private/tmp/drobo_mnt, im Finder über Gehe zu Ordner).")
            Text("3. Für Time Machine: Systemeinstellungen, Allgemein, Time Machine, Optionen, die Drobo zur Liste der ausgeschlossenen Objekte hinzufügen.")
            Text("Wenn beides erledigt ist, in den Einstellungen den Hinweis ausschalten.").foregroundStyle(.secondary)
            HStack { Spacer(); Button("Schließen") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520)
    }
}
