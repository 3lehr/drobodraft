#if DEBUG
import AppKit
import DroboKern
import Foundation
import Network

/// Steuerung per Text, NUR im Debug-Bau und NUR mit Umgebung DROBO_STEUERUNG=<port> (Auslieferungszustand: kein Hoerer). Horcht nur auf 127.0.0.1.
/// GET /aktionen   Aktionskatalog (id, titel, menue, kuerzel, aendert_daten, undo, aktiv), erzeugt aus `Aktion` (dieselbe Quelle wie die Menueleiste)
/// GET /menue      die ECHTE Menueleiste (NSApp.mainMenu): Pfad + Kuerzel je Eintrag, damit der Test Katalog und Menue vergleicht
/// GET /zustand    Bereich, Auswahl, offenes Blatt, Drobo-Liste, Einstellungen, Rueckgaengig-Zustand
/// POST /aktion?id=<id>[&arg=<text>]   fuehrt die Aktion aus (arg ersetzt Eingabeblatt/Ordnerwahl)
/// POST /undo, /redo   Rueckgaengig / Wiederholen ueber den UndoManager
/// POST /bestaetigen[?name=]   Knopf des offenen Schreib-/Formatblatts (Sperre gilt); POST /uhr?versatz=<s> verstellt die Uhr der Sperre; POST /gesichert?an=1 setzt das Sicherungs-Kaestchen
/// GET /symbolmenue   Zeilen des Menueleisten-Symbols (art, titel, aktion, arg, aktiv, frei); POST /fensterschliessen schliesst alle Fenster (App laeuft weiter)
/// GET /text?k=<Schluessel>   Katalogtext in der Sprache des Laufs (Pruefung der Lokalisierung)
/// GET /bild       PNG des Hauptfensters (nur eigener Prozess, keine Bildschirmaufnahme)
/// Dieselben Texte wie die Oberflaeche (Titel kommen aus String(localized:)). Eine Uhr gibt es in der App nicht, nichts zu verstellen.
@MainActor
final class Steuerung {
    private var listener: NWListener?
    private let m: DroboModell
    nonisolated(unsafe) static var halter: Steuerung?

    static func startenWennGewuenscht(_ m: DroboModell) {
        guard halter == nil, let p = ProcessInfo.processInfo.environment["DROBO_STEUERUNG"].flatMap({ UInt16($0) }) else { return }
        let s = Steuerung(m); s.start(p); halter = s
    }
    init(_ m: DroboModell) { self.m = m }

    func start(_ port: UInt16) {
        let par = NWParameters.tcp
        par.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: par, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, _, _ in
                guard let self, let d, let z = String(data: d, encoding: .utf8) else { c.cancel(); return }
                let (status, typ, body) = MainActor.assumeIsolated { self.antwort(auf: z) }
                let kopf = "HTTP/1.1 \(status)\r\nContent-Type: \(typ)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(kopf.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.start(queue: .main); listener = l
    }

    func json(_ o: Any, _ status: String = "200 OK") -> (String, String, Data) {
        (status, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])) ?? Data())
    }

    func antwort(auf anfrage: String) -> (String, String, Data) {
        let teile = (anfrage.split(separator: "\r\n").first ?? "").split(separator: " ")
        guard teile.count >= 2, let u = URLComponents(string: String(teile[1])) else { return json(["fehler": "Anfrage"], "400 Bad Request") }
        let q = Dictionary((u.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        switch (String(teile[0]), u.path) {
        case ("GET", "/aktionen"): return json(Aktion.allCases.map { a in
            let d = a.def
            return ["id": a.id, "titel": d.titel, "menue": a.menuePfad, "kuerzel": d.kuerzel?.text as Any? ?? NSNull(), "aendert_daten": d.aendert, "undo": d.undo, "aktiv": m.aktiv(a), "nur_menue": a.nurMenue, "nur_symbol": d.nurSymbol] as [String: Any]
        })
        case ("GET", "/menue"): return json(menueleiste())
        case ("GET", "/symbolmenue"): return json(m.symbolMenue().map { z in
            ["id": z.id, "art": z.art.rawValue, "titel": z.titel, "symbol": z.symbol as Any? ?? NSNull(), "aktion": z.aktion?.rawValue as Any? ?? NSNull(), "arg": z.arg as Any? ?? NSNull(), "aktiv": z.aktiv, "frei": z.frei.map { Int($0) } as Any? ?? NSNull()] as [String: Any] })
        case ("GET", "/text"):   // Katalogsuche zur Laufzeit in der gestarteten Sprache (-AppleLanguages): "«fehlt»" = Schluessel nicht im Katalog
            return json(["schluessel": q["k"] ?? "", "text": Bundle.main.localizedString(forKey: q["k"] ?? "", value: "«fehlt»", table: nil)])
        case ("POST", "/fensterschliessen"):   // wie der Schliessknopf; die App muss danach weiterlaufen (Symbol in der Menueleiste)
            NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
            return json(["fenster_offen": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count])
        case ("GET", "/zustand"): return json(zustand())
        case ("POST", "/aktion"):
            guard let a = Aktion(rawValue: q["id"] ?? "") else { return json(["ok": false, "fehler": "unbekannte Aktion"], "404 Not Found") }
            let f = m.fuehreAus(a, arg: q["arg"])
            return json(["ok": f == nil, "fehler": f as Any? ?? NSNull()] as [String: Any])
        case ("POST", "/bestaetigen"):   // Knopf des offenen Schreib-/Formatblatts; die Sperre ist NICHT umgehbar, nur die Uhr verstellbar (/uhr)
            let f: String?
            switch m.blatt { case .schreiben: f = m.schreibenBestaetigen(); case .format(let l): f = m.formatBestaetigen(lun: l, name: q["name"] ?? m.aktuell?.eintrag.netz?.luns?.first { $0.lun == l }?.name ?? "DroboPro"); default: f = String(localized: "Kein Blatt offen.") }
            return json(["ok": f == nil, "fehler": f as Any? ?? NSNull()] as [String: Any])
        case ("GET", "/protokoll"): return json(m.ablage.protokollLesen(letzte: 30).map { $0.text })
        case ("POST", "/vorgang"):   // Pruefung der Sperr-Ueberlagerung ohne Geraet: titel=... setzt einen Vorgang an der gewaehlten Drobo, ende=1 loescht ihn
            let n = m.einstellungen.drobos.first { $0.uuid == m.auswahl }?.name ?? ""
            if q["ende"] == "1" { m.vorgaenge[m.auswahl] = nil } else { m.vorgaenge[m.auswahl] = Vorgang(titel: q["titel"] ?? "Formatieren", drobo: n, start: Date()) }
            return json(["vorgaenge": m.vorgaenge.count])
        case ("POST", "/uhr"): m.uhrVersatz = Double(q["versatz"] ?? "0") ?? 0; return json(["versatz": m.uhrVersatz])
        case ("POST", "/gesichert"): m.blattGesichert = q["an"] == "1"; return json(["gesichert": m.blattGesichert])
        case ("POST", "/undo"): let ok = m.undoManager.canUndo; m.undoManager.undo(); return json(["ok": ok])
        case ("POST", "/redo"): let ok = m.undoManager.canRedo; m.undoManager.redo(); return json(["ok": ok])
        case ("GET", "/bild"):
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "DroboDraft" }) ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let v = w.contentView,
                  let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return json(["fehler": "kein Fenster"], "404 Not Found") }
            v.cacheDisplay(in: v.bounds, to: r)
            return ("200 OK", "image/png", r.representation(using: .png, properties: [:]) ?? Data())
        default: return json(["fehler": "unbekannt"], "404 Not Found")
        }
    }

    func zustand() -> [String: Any] {
        let e = (try? JSONEncoder().encode(m.einstellungen)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        return ["abschnitt": m.abschnitt?.rawValue ?? "", "auswahl": m.auswahl, "blatt": m.blatt?.id as Any? ?? NSNull(),
                "drobos": m.einstellungen.drobos.map { ["uuid": $0.uuid, "name": $0.name, "rolle": $0.rolle.rawValue] },
                "vorgang": m.vorgaenge[m.auswahl]?.titel as Any? ?? NSNull(), "vorgaenge": m.vorgaenge.count, "suchlaeufe": m.sucheZaehler, "blatt_art": blattArtText(), "sperre_rest": m.sperreRest(), "gesichert": m.blattGesichert, "bestaetigt": m.bestaetigt.mapValues { "\($0.build.map(String.init) ?? "-")/\($0.anschluss)/\($0.schreibweg)" },
                "einstellungen": e, "aktivierung_soll": DroboModell.aktivierung(nurMenueleiste: m.einstellungen.nurMenueleiste) == .accessory ? "accessory" : "regular", "kann_undo": m.undoManager.canUndo, "kann_redo": m.undoManager.canRedo, "undo_titel": m.undoManager.undoActionName] as [String: Any]
    }

    func blattArtText() -> String {
        switch m.blatt { case .schreiben: if case .voll(let g) = m.blattArtOffen { return "voll:" + g.rawValue }; return "kurz"; case .format: return "voll:formatieren"; default: return "" }
    }

    func menueleiste() -> [[String: Any]] {
        var z: [[String: Any]] = []
        for top in NSApp.mainMenu?.items ?? [] {
            for i in top.submenu?.items ?? [] where !i.isSeparatorItem && !i.title.isEmpty {
                var k = ""
                if !i.keyEquivalent.isEmpty {
                    let m = i.keyEquivalentModifierMask
                    let taste = i.keyEquivalent == "\u{8}" || i.keyEquivalent == "\u{7f}" ? "⌫" : i.keyEquivalent.uppercased()
                    k = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + taste
                }
                z.append(["pfad": top.title + " > " + i.title, "kuerzel": k.isEmpty ? NSNull() : k, "aktiv": i.isEnabled])
            }
        }
        return z
    }
}
#endif
