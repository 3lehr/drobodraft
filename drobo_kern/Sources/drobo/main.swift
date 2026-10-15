import DroboKern
import Foundation

func hilfe() -> Never {
    print("""
    drobo status [--json] [--uuid U]
    drobo einhaengen [--schreiben] [--ort PFAD] [--uuid U]     (Vorgabe nurlesen, Ort \(vorgabeOrt), nie unter $HOME)
    drobo aushaengen [--uuid U]
    drobo freigabe nurlesen|schreiben|entfernen [--uuid U]
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
    case "helfer":
        guard let a = args.first, a == "freigeben" || a == "zurueckgeben" else { hilfe() }
        if let f = helferAufruf(a, uuid: kern.uuid) { throw Fehler.helfer(f) }
        print("\(a) ok")
    default: hilfe()
    }
} catch let f as Fehler {
    FileHandle.standardError.write(Data("FEHLER: \(f)\n".utf8)); exit(f.code)
} catch {
    FileHandle.standardError.write(Data("FEHLER: \(error)\n".utf8)); exit(1)
}
