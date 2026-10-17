import DroboKern
import SwiftUI

/// Bogen von -135 bis +135 Grad (270 Grad Rundinstrument); `bis` = Anteil 0...1.
struct BogenForm: Shape {
    var bis: Double
    var animatableData: Double { get { bis } set { bis = newValue } }
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: min(r.width, r.height) / 2 - 12,
                 startAngle: .degrees(135), endAngle: .degrees(135 + 270 * min(max(bis, 0), 1)), clockwise: false)
        return p
    }
}

/// Rundinstrument in MB/s. Der Wert steht groß als Text (Information nie nur im Bogen); VoiceOver liest Titel und Wert.
struct Rundinstrument: View {
    let titel: LocalizedStringKey
    let wert: Double?
    let skala: Double
    let aktiv: Bool
    /// Zeitpunkt der angezeigten Messung (ISO), nil = live oder noch nie gemessen. Alte Werte einer getrennten Drobo duerfen nicht wie aktuelle aussehen.
    var stand: String?
    @Environment(\.accessibilityReduceMotion) private var wenigBewegung

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                BogenForm(bis: 1).stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                BogenForm(bis: (wert ?? 0) / max(skala, 1))
                    .stroke(aktiv ? Color.accentColor : Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .animation(wenigBewegung ? nil : .linear(duration: 0.25), value: wert)
                VStack(spacing: 0) {
                    Text(wert.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "–").font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("MB/s").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            HStack { Text("0"); Spacer(); Text(String(format: "%.0f", skala)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 150)
            Text(titel).font(.headline)
            if let s = stand { Text("Gemessen: \(zeitLesbar(s))").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(titel))
        .accessibilityValue((wert.map { String(localized: "\(Int($0)) Megabyte pro Sekunde") } ?? String(localized: "noch nicht gemessen")) + (stand.map { ", " + String(localized: "Gemessen: \(zeitLesbar($0))") } ?? ""))
    }
}

enum TempoBasis: String, CaseIterable, Identifiable { case schreiben, lesen; var id: String { rawValue } }
enum TempoSicht: String, CaseIterable, Identifiable { case reicht, wieSchnell; var id: String { rawValue } }

struct TempoAnsicht: View {
    @EnvironmentObject var m: DroboModell
    @State private var basis: TempoBasis = .schreiben
    @State private var sicht: TempoSicht = .reicht
    @State private var bildrate = 30

    var ziel: DroboAnsicht? { m.tempoZiel }
    var letzte: (schreiben: Double?, lesen: Double?) {
        let l = m.tempo.filter { $0.uuid == ziel?.eintrag.uuid }
        return (l.last(where: { $0.art == "schreiben" })?.mbProSekunde, l.last(where: { $0.art == "lesen" })?.mbProSekunde)
    }
    func stand(_ art: String) -> String? { m.tempo.last(where: { $0.uuid == ziel?.eintrag.uuid && $0.art == art })?.zeit }
    var tabellenRate: Double? { (basis == .schreiben ? letzte.schreiben : letzte.lesen) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tempo").font(.largeTitle).accessibilityAddTraits(.isHeader)
                Karte(titel: "Messung") {
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Picker("Laufwerk", selection: $m.tempoUUID) {
                            ForEach(m.liste.filter { $0.eintrag.rolle == .arbeitsvolume }, id: \.eintrag.uuid) { d in Text("\(d.eintrag.name), \(d.zustandText)").tag(d.eintrag.uuid) }
                        }.frame(maxWidth: 380)
                        Picker("Testgröße", selection: $m.tempoGB) {
                            ForEach(1...5, id: \.self) { Text("\($0) GB").tag($0) }
                        }.frame(maxWidth: 200)
                    }.disabled(m.tempoLaeuft)
                    HStack(alignment: .top, spacing: 36) {
                        Rundinstrument(titel: "Schreiben", wert: m.tempoSchreibenLive ?? letzte.schreiben, skala: m.tempoSkala, aktiv: m.tempoPhase == "schreiben", stand: m.tempoSchreibenLive == nil ? stand("schreiben") : nil)
                        Rundinstrument(titel: "Lesen", wert: m.tempoLesenLive ?? letzte.lesen, skala: m.tempoSkala, aktiv: m.tempoPhase == "lesen", stand: m.tempoLesenLive == nil ? stand("lesen") : nil)
                    }.frame(maxWidth: .infinity)
                    if m.tempoLaeuft {
                        ProgressView(value: m.tempoAnteil) { Text(m.tempoPhase == "schreiben" ? "Schreibt …" : "Liest …") }
                            .accessibilityValue("\(Int(m.tempoAnteil * 100)) %")
                    }
                    HStack {
                        Button { m.tempoLaeuft ? m.tempoStoppen() : m.tempoStarten() } label: {
                            Label(m.tempoLaeuft ? "Stopp" : "Messung starten", systemImage: m.tempoLaeuft ? "stop.fill" : "play.fill")
                        }
                        .keyboardShortcut("t", modifiers: .command)
                        .disabled(!m.tempoLaeuft && !m.tempoStartbar)
                        if m.tempoZyklen > 0 { Text("Durchläufe: \(m.tempoZyklen)").font(.callout).foregroundStyle(.secondary) }
                    }
                    if let f = m.tempoFehler { Hinweis(symbol: "exclamationmark.triangle.fill", text: LocalizedStringKey(f), farbe: .red) }
                    modusHinweis
                }
                Karte(titel: "Reicht die Drobo für Video?") {
                    HStack(spacing: 24) {
                        Picker("Ansicht", selection: $sicht) {
                            Text("Reicht es?").tag(TempoSicht.reicht); Text("Wie schnell?").tag(TempoSicht.wieSchnell)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                        Picker("Gemessen mit", selection: $basis) {
                            Text("Schreiben").tag(TempoBasis.schreiben); Text("Lesen").tag(TempoBasis.lesen)
                        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                        if sicht == .reicht {
                            Picker("Bildrate", selection: $bildrate) { ForEach(proResBildraten, id: \.self) { Text("\($0) fps").tag($0) } }.frame(maxWidth: 170)
                        }
                    }
                    if let r = tabellenRate {
                        Text("Grundlage: \(Int(r.rounded())) MB/s (\(basis == .schreiben ? String(localized: "Schreiben") : String(localized: "Lesen")))").font(.callout).foregroundStyle(.secondary)
                        FormatTabelle(mbs: r, sicht: sicht, bildrate: bildrate)
                    } else {
                        Text("Noch keine Messung dieser Art. Erst messen, dann zeigt die Tabelle, welche Videoformate die Drobo trägt.").foregroundStyle(.secondary)
                    }
                    Text("Datenraten laut \(proResQuelle). Zielwerte; echte Dateien weichen etwas ab (variable Bitrate). Andere Formate (Blackmagic RAW, H.264, H.265) fehlen, weil es dafür keine belegbare Herstellertabelle gibt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Karte(titel: "Verlauf") {
                    let l = Array(m.tempo.filter { $0.uuid == ziel?.eintrag.uuid }.suffix(8).reversed())
                    if l.isEmpty { Text("Noch keine Messung.").foregroundStyle(.secondary) }
                    ForEach(Array(l.enumerated()), id: \.offset) { _, t in
                        HStack {
                            Text(zeitLesbar(t.zeit)).font(.caption.monospacedDigit())
                            Text(t.art == "lesen" ? "lesen" : "schreiben").font(.caption)
                            Spacer()
                            Text(String(format: "%.0f MB/s", t.mbProSekunde)).font(.callout.monospacedDigit())
                        }.accessibilityElement(children: .combine)
                    }
                }
            }.padding(20)
        }
        .onAppear { m.tempoZielWaehlen() }
        .onChange(of: m.tempoLaeuft) { _, laeuft in if !laeuft { basis = letzte.schreiben != nil ? .schreiben : .lesen } }
    }

    @ViewBuilder var modusHinweis: some View {
        if let z = ziel, z.eingehaengt {
            if z.nurlesen {
                Text("Nur lesen: gemessen wird das Lesen großer vorhandener Dateien auf der Drobo. Es wird nichts geschrieben. Für Schreibtempo zum Schreiben einhängen.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Schreiben: eine Testdatei im Ordner .drobodraft_speedtest wird geschrieben, wieder gelesen und danach gelöscht. Freier Platz von mindestens der doppelten Testgröße ist nötig; die Metadaten-Sicherung muss vorliegen.").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            Text("Zum Messen die Drobo einhängen (Ansicht Übersicht).").font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Tabelle Auflösung x Codec: ✓/✗ für eine Bildrate bzw. höchste tragbare Bildrate. Zeichen UND Text, nie nur Farbe.
struct FormatTabelle: View {
    let mbs: Double
    let sicht: TempoSicht
    let bildrate: Int
    static let kurz = ["422 Proxy", "422 LT", "422", "422 HQ", "4444", "4444 XQ"]

    func zelle(_ a: ProResAufloesung, _ c: Int) -> some View {
        let name = "\(proResCodecs[c]), \(a.name)"
        return Group {
            switch sicht {
            case .reicht:
                let ok = a.reicht(mbProSekunde: mbs, codec: c, fps: bildrate) ?? false
                Label(ok ? "ja" : "nein", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.red)
                    .accessibilityLabel(Text("\(name), \(bildrate) fps: \(ok ? String(localized: "reicht") : String(localized: "reicht nicht"))"))
            case .wieSchnell:
                let f = a.maxBilder(mbProSekunde: mbs, codec: c) ?? 0
                Text(f >= 1000 ? "999+" : String(format: "%.0f", f)).monospacedDigit()
                    .accessibilityLabel(Text("\(name): \(Int(min(f, 999))) \(String(localized: "Bilder pro Sekunde"))"))
            }
        }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Auflösung").font(.caption.bold())
                ForEach(0..<proResCodecs.count, id: \.self) { Text(Self.kurz[$0]).font(.caption.bold()).accessibilityLabel(Text(proResCodecs[$0])) }
            }
            Divider()
            ForEach(proResTabelle, id: \.name) { a in
                GridRow {
                    Text(a.name).font(.callout.monospacedDigit())
                    ForEach(0..<proResCodecs.count, id: \.self) { c in zelle(a, c) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Formattabelle"))
    }
}
