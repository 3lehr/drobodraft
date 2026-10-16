import DroboKern
import Foundation

func hilfe() -> Never {
    print("""
    drobo status [--json] [--uuid U]
    drobo einhaengen [--schreiben] [--ort PFAD] [--uuid U]     (Vorgabe nurlesen, Ort \(vorgabeOrt), nie unter $HOME)
    drobo aushaengen [--uuid U]
    drobo freigabe nurlesen|schreiben|entfernen [--uuid U]
    drobo sichern [--ort PFAD] [--anzahl N]      (Metadaten-Sicherung, Volume ausgehaengt; Vorgabe aus Einstellungen)
    drobo pruefen [--ohne-katalog]               (Nachpruefung, Volume ausgehaengt, nur lesend)
    drobo wegsichern QUELLE ZIEL                 (Quelle auf der eingehaengten Drobo; Ziel nie darauf)
    drobo tempo [--schreiben]                    (Lesetempo; Schreiben nur rw + Sicherung)
    drobo sicherungen                           (Liste, neueste zuerst)
    drobo zurueckspielen NAME [--ausfuehren]    (Probelauf; mit --ausfuehren schreiben, nur ausgehaengt, ueberschreibt alles seit der Sicherung)
    drobo merker | protokoll | tempoverlauf | drobos
    drobo drobo-hinzufuegen UUID NAME [timemachine]
    drobo helfer freigeben|zurueckgeben [--uuid U]      (Diagnose: ruft den Hilfsdienst direkt)
    Umgebung: DROBO_UUID, DROBO_FREIGABE. Exit-Codes: 0 ok, 2 Eingabe, 10-21 siehe Meldung.
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { hilfe() }
let cmd = args.removeFirst()
func opt(_ n: String) -> String? { if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }; return nil }
func flag(_ n: String) -> Bool { args.contains(n) }

do {
    var kern = Kern()
    if let u = opt("--uuid") { kern.uuid = u.uppercased() }
    switch cmd {
    case "status":
        let z = try kern.zustand()
        if flag("--json") {
            print(String(decoding: try JSONSerialization.data(withJSONObject: z.json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else { print(z.text) }
    case "einhaengen":
        let e = try kern.einhaengen(modus: flag("--schreiben") ? .schreiben : .nurlesen, ort: opt("--ort") ?? vorgabeOrt)
        print("eingehaengt \(e.nurlesen ? "ro" : "rw"): \(e.ort)")
    case "aushaengen":
        try kern.aushaengen(); print("ausgehaengt")
    case "freigabe":
        if args.first == "entfernen" { try kern.freigabeEntfernen(); print("Freigabe \(kern.uuid): entfernt"); break }
        guard let m = args.first.flatMap(Modus.init(rawValue:)) else { hilfe() }
        try kern.freigabeSetzen(m); print("Freigabe \(kern.uuid): \(m.rawValue)")
    case "sichern", "pruefen":
        guard let m = finden(uuid: kern.uuid) else { throw Fehler.nichtGefunden(kern.uuid) }
        if einhaengungen()[m.geraet] != nil { throw Fehler.eingehaengt(m.geraet) }
        if let h = kern.helfer("freigeben", kern.uuid) { FileHandle.standardError.write(Data("HINWEIS: Hilfsdienst: \(h)\n".utf8)) }
        defer { _ = kern.helfer("zurueckgeben", kern.uuid) }
        if cmd == "sichern" {
            let e = kern.ablage.einstellungen()
            let r = try metadatenSichern(quelle: m.rohgeraet, ort: opt("--ort") ?? e.sicherungOrt, uuid: kern.uuid, anzahl: opt("--anzahl").flatMap(Int.init) ?? e.sicherungAnzahl, partitionsgroesse: m.groesse)
            print("gesichert: \(r.ordner) (\(r.dateien) Dateien)")
        } else {
            let r = try nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse, tief: !flag("--ohne-katalog"))
            r.hinweise.forEach { print("HINWEIS: \($0)") }
            print(r.ok ? "PRUEFUNG OK (Katalog: \(r.tiefe.rawValue))" : "PRUEFUNG FEHLER: " + r.probleme.joined(separator: "; "))
            if !r.ok { exit(33) }
        }
    case "wegsichern":
        guard args.count >= 2 else { hilfe() }
        let b = try kern.wegsichern(quelle: args[0], ziel: args[1])
        print(b.text); if !b.ok { exit(35) }
    case "tempo":
        let r = try kern.tempoTesten(schreiben: flag("--schreiben"))
        print(String(format: "%@: %.1f MB/s (%d Dateien, %llu Byte)", r.art, r.mbProSekunde, r.dateien, r.bytes))
    case "sicherungen": kern.sicherungen().forEach { print($0) }
    case "zurueckspielen":
        guard let n = args.first else { hilfe() }
        if flag("--ausfuehren") {
            let r = try kern.zurueckspielen(sicherung: n)
            print("zurueckgespielt; Pruefung danach: " + (r.ok ? "in Ordnung" : "AUFFAELLIG: " + r.probleme.joined(separator: "; ")))
        } else {
            let p = try kern.zurueckspielenProbe(sicherung: n)
            print(p.text); print("Probelauf, nichts geschrieben. Zum Schreiben: --ausfuehren (alles seit der Sicherung Geschriebene geht verloren)")
        }
    case "merker":
        let m = kern.ablage.merker(kern.uuid)
        print(String(decoding: try JSONEncoder().encode(m), as: UTF8.self))
    case "protokoll": kern.ablage.protokollLesen().forEach { print("\($0.zeit)  \($0.text)") }
    case "tempoverlauf": kern.ablage.tempoVerlauf().forEach { print("\($0.zeit)  \($0.art)  \(String(format: "%.1f", $0.mbProSekunde)) MB/s") }
    case "drobos": kern.ablage.einstellungen().drobos.forEach { print("\($0.uuid)  \($0.name)  \($0.rolle.rawValue)") }
    case "drobo-hinzufuegen":
        guard args.count >= 2 else { hilfe() }
        var e = kern.ablage.einstellungen(); e.drobos.removeAll { $0.uuid == args[0].uppercased() }
        e.drobos.append(DroboEintrag(uuid: args[0], name: args[1], rolle: args.count > 2 && args[2] == "timemachine" ? .timemachine : .arbeitsvolume))
        kern.ablage.einstellungenSetzen(e); print("ok")
    case "helfer":
        guard let a = args.first, a == "freigeben" || a == "zurueckgeben" else { hilfe() }
        if let f = helferAufruf(a, uuid: kern.uuid) { throw Fehler.helfer(f) }
        print("\(a) ok")
    default: hilfe()
    }
} catch let f as Fehler {
    FileHandle.standardError.write(Data("FEHLER: \(f)\n".utf8)); exit(f.code)
} catch let f as AppFehler {
    FileHandle.standardError.write(Data("FEHLER: \(f)\n".utf8)); exit(f.code)
} catch {
    FileHandle.standardError.write(Data("FEHLER: \(error)\n".utf8)); exit(1)
}
