import DroboKern
import Foundation

private let adressSucheSperre = NSLock()
private var adressSucheZeit: [String: Date] = [:]     // IQN -> letzte Suche (hoechstens alle 5 min: der LAN-Scan kostet bis zu 30 s)

/// Netzwerk-Drobo (DroboPro): LUN-Verwaltung, feste Kennung (IQN) und Adresswechsel, Umbenennen.
extension DroboModell {
    /// Kontakt gelungen: LUN-Liste lesen; fehlende IQN nachtragen und die LUN-Namen des Eintrags abgleichen. Neues Ziel nur, wenn sich etwas aendert.
    nonisolated static func netzKontakt(_ nz: NetzZiel) -> (luns: [LunEintrag], ziel: NetzZiel?) {
        let l = (try? netzLunVerzeichnis(host: nz.host)) ?? []
        var n = nz
        if n.iqn == nil { n.iqn = try? netzZielName(host: nz.host) }
        if !l.isEmpty {
            let alt = Dictionary(uniqueKeysWithValues: (nz.luns ?? []).map { ($0.lun, $0) })
            n.luns = l.compactMap { e in e.uuid.map { NetzLunEintrag(lun: e.lun, uuid: $0, name: alt[e.lun]?.name ?? String(localized: "Volume \(e.lun + 1)")) } }
        }
        return (l, n == nz ? nil : n)
    }

    /// Host nicht erreichbar: ueber die feste IQN wiederfinden (nie ohne IQN, nie bei anderer IQN). Protokoll: "Adresse geändert: alt → neu" oder "nicht erreichbar".
    nonisolated static func netzAdresseNachfuehren(_ nz: NetzZiel, ablage: Datenablage, ausnehmen: Set<String>) -> NetzZiel? {
        guard let iqn = nz.iqn else { return nil }
        adressSucheSperre.lock()
        let zuletzt = adressSucheZeit[iqn] ?? .distantPast
        if Date().timeIntervalSince(zuletzt) < 300 { adressSucheSperre.unlock(); return nil }
        adressSucheZeit[iqn] = Date(); adressSucheSperre.unlock()
        guard let h = netzAdresseSuchen(iqn: iqn, ausnehmen: ausnehmen), h != nz.host else {
            ablage.protokoll("Netzwerk-Drobo nicht erreichbar: \(nz.host)"); return nil
        }
        ablage.protokoll("Adresse geändert: \(nz.host) → \(h)")
        var n = nz; n.host = h; return n
    }

    func zieleUebernehmen(_ z: [String: NetzZiel]) {
        guard !z.isEmpty else { return }
        for (u, n) in z { if let i = einstellungen.drobos.firstIndex(where: { $0.uuid == u }) { einstellungen.drobos[i].netz = n } }
        ablage.einstellungenSetzen(einstellungen)
    }

    // MARK: LUNs einhaengen / aushaengen / formatieren

    func lunEinhaengen(_ lun: Int, schreiben: Bool) {
        guard let nz = aktuell?.eintrag.netz else { return }
        let e = einstellungen, fp = weckFortschritt(aktuell?.eintrag.uuid ?? ""), name = nz.luns?.first { $0.lun == lun }?.name
        ausfuehren(schreiben ? "Zum Schreiben einhängen" : "Einhängen") { [ablage] in
            try iscsiEinhaengen(host: nz.host, lun: lun, schreiben: schreiben, ziel: nil, ort: iscsiEinhaengeort(einstellung: e.einhaengeort), sicherung: schreiben ? (e.sicherungOrt, e.sicherungAnzahl) : nil, volumenName: name, meldung: { ablage.protokoll("Netzwerk-Drobo LUN \(lun): \($0)") }, weckfortschritt: fp)
            return nil
        }
    }

    func lunAushaengen(_ lun: Int) {
        ausfuehren("Aushängen") { [ablage] in try iscsiAushaengen(lun: lun); ablage.protokoll("Netzwerk-Drobo LUN \(lun) ausgehängt"); return nil }
    }

    func alleLunsEinhaengen() {
        guard let nz = aktuell?.eintrag.netz else { return }
        let e = einstellungen, namen = Dictionary((nz.luns ?? []).map { ($0.lun, $0.name) }, uniquingKeysWith: { a, _ in a })
        ausfuehren("Alle einhängen") { [ablage] in
            let r = try iscsiAlleEinhaengen(host: nz.host, schreiben: false, ort: iscsiEinhaengeort(einstellung: e.einhaengeort), namen: namen, meldung: { ablage.protokoll("Netzwerk-Drobo: \($0)") })
            let fehler = r.filter { $0.value != nil }.keys.sorted()
            return fehler.isEmpty ? nil : String(localized: "Nicht jede virtuelle Festplatte ließ sich einhängen. Einzelheiten stehen im Protokoll.")
        }
    }

    func alleLunsAushaengen() { ausfuehren("Alle aushängen") { [ablage] in try iscsiAlleAushaengen(meldung: { ablage.protokoll("Netzwerk-Drobo: \($0)") }); return nil } }

    /// Formatiert eine LUN neu (alle Daten dieser LUN gehen verloren). Nur DroboPro-Testgeraet; nie eine eingehaengte LUN (Kern verweigert). Arbeitsordner = Sicherungsort (anderes Laufwerk, >= 20 GiB frei).
    func lunFormatieren(_ lun: Int, name: String) {
        guard let nz = aktuell?.eintrag.netz, let u = aktuell?.eintrag.uuid else { return }
        let ort = einstellungen.sicherungOrt
        guard !ort.isEmpty else { meldung = Meldung(titel: "Formatieren nicht möglich", text: String(localized: "Wähle zuerst einen Sicherungsort (anderes Laufwerk als die Drobo und das Startvolume): Beim Formatieren wird dort kurz ein Abbild der neuen Partition aufgebaut (mindestens 20 GB frei).")); return }
        ausfuehren("Formatieren") { [ablage] in
            let port = try helferISCSIWeiterleitung(host: nz.host)
            try iscsiFormat(host: "127.0.0.1", port: port, lun: lun, name: name, ausfuehren: true, arbeitsordner: ort, meldung: { ablage.protokoll("Formatieren LUN \(lun): \($0)") })
            let neu = try? netzLunVerzeichnis(host: nz.host)
            await MainActor.run { [weak self] in
                guard let self, let i = self.einstellungen.drobos.firstIndex(where: { $0.uuid == u }), var n = self.einstellungen.drobos[i].netz, let e = neu?.first(where: { $0.lun == lun }), let id = e.uuid else { return }
                var l = (n.luns ?? []).filter { $0.lun != lun }; l.append(NetzLunEintrag(lun: lun, uuid: id, name: name)); n.luns = l.sorted { $0.lun < $1.lun }
                self.einstellungen.drobos[i].netz = n; self.ablage.einstellungenSetzen(self.einstellungen)
            }
            return String(localized: "Fertig. Die virtuelle Festplatte ist neu formatiert und kann eingehängt werden.")
        }
    }

    // MARK: Umbenennen (App-Name)

    func umbenennen(_ uuid: String, name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = einstellungen.drobos.firstIndex(where: { $0.uuid == uuid }) else { return }
        aendern(String(localized: "Drobo umbenennen")) { $0.drobos[i].name = n }
    }
}
