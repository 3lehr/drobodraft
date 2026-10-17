import DroboKern
import SwiftUI

enum Abschnitt: String, CaseIterable, Identifiable {
    case uebersicht = "Übersicht", laufwerke = "Laufwerke", protokoll = "Protokoll", tempo = "Tempo", volume = "Ordner sichern", finden = "Drobos finden"
    var id: String { rawValue }
    static let ansicht: [Abschnitt] = [.uebersicht, .laufwerke, .protokoll]
    static let werkzeuge: [Abschnitt] = [.tempo, .volume]
    var symbol: String {
        switch self {
        case .uebersicht: return "gauge.with.dots.needle.33percent"; case .volume: return "externaldrive.badge.timemachine"; case .tempo: return "speedometer"
        case .protokoll: return "list.bullet.rectangle"; case .laufwerke: return "internaldrive"; case .finden: return "magnifyingglass"
        }
    }
}

/// Links: Drobos (mit Zustandspunkt UND Text), "Drobos finden", Ansicht, Werkzeuge. Die Auswahl steht als Hervorhebung + Eigenschaft "ausgewaehlt", nicht als Haekchen.
struct Seitenleiste: View {
    @EnvironmentObject var m: DroboModell
    @Binding var abschnitt: Abschnitt?

    var body: some View {
        List {
            Section("Drobos") {
                if m.liste.isEmpty { Text("Keine Drobo eingerichtet").foregroundStyle(.secondary) }
                ForEach(m.liste, id: \.eintrag.uuid) { d in
                    let gewaehlt = m.auswahl == d.eintrag.uuid && abschnitt != .finden
                    let zeile = d.hwZustand.flatMap { $0.stufe == .ok ? nil : $0.schlagzeile.text } ?? d.zustandText
                    Button { m.auswahl = d.eintrag.uuid; if abschnitt == .finden { abschnitt = .uebersicht } } label: {
                        HStack {
                            ZustandPunkt(stufe: d.stufe, gesamt: d.hwZustand)
                            VStack(alignment: .leading, spacing: 1) { Text(d.eintrag.name); Text(zeile).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(gewaehlt ? Color.accentColor.opacity(0.28) : Color.clear)
                    .contextMenu { Button("Umbenennen …") { m.umbenennenUUID = d.eintrag.uuid } }
                    .accessibilityAction(named: Text("Umbenennen …")) { m.umbenennenUUID = d.eintrag.uuid }
                    .accessibilityLabel("\(d.eintrag.name), \(zeile)")
                    .accessibilityAddTraits(gewaehlt ? [.isSelected, .isButton] : .isButton)
                }
                eintrag(.finden)
            }
            Section("Ansicht") { ForEach(Abschnitt.ansicht) { eintrag($0) } }
            Section("Werkzeuge") { ForEach(Abschnitt.werkzeuge) { eintrag($0) } }
        }
    }

    func eintrag(_ a: Abschnitt) -> some View {
        let gewaehlt = (abschnitt ?? .uebersicht) == a
        let neu = a == .finden ? m.erkannte.count + m.lanErkannte.reduce(0) { $0 + $1.luns.count } : 0
        return Button { abschnitt = a } label: {
            HStack {
                Label(LocalizedStringKey(a.rawValue), systemImage: a.symbol).fontWeight(gewaehlt ? .bold : .regular)
                Spacer()
                if a == .finden && m.sucheLaeuft { ProgressView().controlSize(.small).accessibilityLabel("Suche läuft …") }
                if neu > 0 { Text("\(neu) neu").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor.opacity(0.25), in: Capsule()) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(gewaehlt ? Color.accentColor.opacity(0.28) : Color.clear)
        .accessibilityLabel(neu > 0 ? String(localized: "\(String(localized: String.LocalizationValue(a.rawValue))), \(neu) neu") : String(localized: String.LocalizationValue(a.rawValue)))
        .accessibilityAddTraits(gewaehlt ? [.isSelected, .isButton] : .isButton)
    }
}
