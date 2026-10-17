import DroboKern
import SwiftUI

func anschlussWort(_ a: Anschluss) -> String {
    switch a {
    case .usb: return String(localized: "USB")
    case .iscsiWLAN: return String(localized: "WLAN")
    case .iscsiKabel: return String(localized: "Kabel")
    case .firewire: return String(localized: "FireWire")
    case .iscsiUnbekannt: return String(localized: "einen nicht erkannten Netzwerkanschluss")
    }
}

/// Satz, der genau benennt, was an der Drobo des Nutzers von der naechsten erprobten Kombination abweicht.
func abweichungsText(modell: String, build: Int?, anschluss: Anschluss, naechster n: ErprobtEintrag?, ok: Set<Merkmal>, ab: Set<Merkmal>) -> String {
    let aw = anschlussWort(anschluss)
    guard let n, ok.contains(.modell) else {
        let b = build.map { String($0) } ?? String(localized: "unbekannt")
        return String(localized: "Dieses Modell ist für diese Aktion noch nicht erprobt: \(modell) · Firmware \(b) · über \(aw).")
    }
    switch (ab.contains(.firmware), ab.contains(.anschluss)) {
    case (false, true): return String(localized: "\(n.anzeige) und Firmware erprobt, der Anschluss über \(aw) noch nicht.")
    case (true, false):
        if let b = build { return String(localized: "\(n.anzeige) erprobt, Ihre Firmware \(String(b)) nicht.") }
        return String(localized: "\(n.anzeige) erprobt, die Firmware Ihrer Drobo ließ sich nicht lesen.")
    default: return String(localized: "\(n.anzeige) erprobt, Ihre Firmware und der Anschluss über \(aw) nicht.")
    }
}

/// "Erprobt mit": steht IM Bestaetigungsblatt (kein zweites Popup). Voller Treffer = ruhiger Hinweis; sonst Warnblock (Symbol + Text) mit den erprobten Kombinationen
/// und einem Kaestchen, das die Bestaetigung erst freigibt.
struct ErprobtBlock: View {
    @EnvironmentObject var m: DroboModell
    let aktion: ErprobtAktion
    @Binding var gesichert: Bool

    var body: some View {
        let h = m.aktuell?.hw
        let modell = h.map { $0.modell.hasPrefix("Drobo") ? $0.modell : "Drobo \($0.modell)" } ?? String(localized: "Unbekanntes Modell")
        switch m.erprobtErgebnis(aktion) {
        case .erprobt(let x):
            Label { Text("Ihre Drobo entspricht der erprobten: \(x.anzeige) · Firmware \(String(x.firmwareBuild)) · über \(anschlussWort(x.anschluss)).") } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green) }
                .font(.callout).accessibilityElement(children: .combine)
        case .nichtErprobt(let liste, let n, let ok, let ab):
            VStack(alignment: .leading, spacing: Abstand.s) {
                Hinweis(symbol: "exclamationmark.triangle.fill", text: LocalizedStringKey(abweichungsText(modell: modell, build: h?.firmwareBuild, anschluss: m.anschluss, naechster: n, ok: ok, ab: ab)))
                VStack(alignment: .leading, spacing: Abstand.xs) {
                    Text("Bisher erprobt für diese Aktion:").font(.callout.bold())
                    ForEach(Array(liste.enumerated()), id: \.offset) { _, x in
                        Text("• \(x.anzeige) · Firmware \(String(x.firmwareBuild)) · über \(anschlussWort(x.anschluss))").font(.callout)
                    }
                }.accessibilityElement(children: .combine)
                Toggle("Ich habe eine aktuelle Sicherung meiner Daten.", isOn: $gesichert)
            }
        }
    }
}
