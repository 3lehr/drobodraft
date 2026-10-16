import DroboKern
import Foundation

func hilfe() -> Never {
    print("""
    drobo - DroboDraft command line (messages from the core are still German; German command names work as aliases)

    drobo status [--json] [--uuid U]
    drobo mount [--write] [--path DIR] [--uuid U]    default read-only; DIR default \(vorgabeOrt) ('/Volumes' = /Volumes/<volume name>), never under $HOME
    drobo unmount [--uuid U]
    drobo permission read-only|write|remove [--uuid U]     module permission list (aliases: freigabe nurlesen|schreiben|entfernen)
    drobo backup [--path DIR] [--keep N]       back up the management data (volume unmounted); default from settings
    drobo backup-location [DIR]                show or set the backup location (not the startup volume, not the Drobo)
    drobo backups                              list backups, newest first
    drobo check [--no-catalog]                 check the unmounted volume, read-only
    drobo restore NAME [--execute]             dry run; with --execute write it back (unmounted only, loses everything written since the backup)
    drobo copy-folder SOURCE TARGET            copy a folder from the mounted Drobo to another disk (incremental, SHA-256 verified)
    drobo speed [--write]                      read speed; write speed only when mounted writable with a backup
    drobo access                               check without effect whether the helper may reach the device
    drobo state | log | speed-history | drives
    drobo add-drive UUID NAME [timemachine]
    drobo helper grant|release [--uuid U]      diagnostics: call the helper directly (aliases: helfer freigeben|zurueckgeben)
    drobo uninstall                            print how to remove DroboDraft (tools/uninstall.sh)
    Environment: DROBO_UUID, DROBO_FREIGABE, DROBO_DATEN, DROBO_BUNDLE_PREFIX, DROBO_WERKZEUGE. Exit codes: 0 ok, 2 usage, 10-36 see message.
    """)
    exit(2)
}

/// Deutsche Namen bleiben als Aliasse (Skripte, Gewohnheit).
let befehlAlias = ["einhaengen": "mount", "aushaengen": "unmount", "freigabe": "permission", "sichern": "backup", "pruefen": "check", "wegsichern": "copy-folder",
                   "tempo": "speed", "zugriff": "access", "sicherungen": "backups", "zurueckspielen": "restore", "merker": "state", "protokoll": "log",
                   "tempoverlauf": "speed-history", "drobos": "drives", "drobo-hinzufuegen": "add-drive", "helfer": "helper"]
let flagAlias = ["--schreiben": "--write", "--ort": "--path", "--anzahl": "--keep", "--ohne-katalog": "--no-catalog", "--ausfuehren": "--execute"]
let wortAlias = ["nurlesen": "read-only", "schreiben": "write", "entfernen": "remove", "freigeben": "grant", "zurueckgeben": "release"]

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, args.first != "--help", args.first != "-h", args.first != "help" else { hilfe() }
var cmd = args.removeFirst(); cmd = befehlAlias[cmd] ?? cmd
args = args.map { flagAlias[$0] ?? ($0.hasPrefix("-") ? $0 : (wortAlias[$0] ?? $0)) }
func opt(_ n: String) -> String? { if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }; return nil }
func flag(_ n: String) -> Bool { args.contains(n) }
func meldung(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

do {
    var kern = Kern()
    if let u = opt("--uuid") { kern.uuid = u.uppercased() }
    switch cmd {
    case "status":
        let z = try kern.zustand()
        if flag("--json") {
            print(String(decoding: try JSONSerialization.data(withJSONObject: z.json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else { print(z.text) }
    case "mount":
        let e = try kern.einhaengen(modus: flag("--write") ? .schreiben : .nurlesen, ort: opt("--path") ?? vorgabeOrt)
        print("mounted \(e.nurlesen ? "read-only" : "writable"): \(e.ort)")
    case "unmount":
        let p = try kern.aushaengen(); print("unmounted"); if let p = p, !p.ok { print("CHECK AFTER WRITING FOUND ISSUES: " + p.probleme.joined(separator: "; ")); exit(33) }
    case "permission":
        if args.first == "remove" { try kern.freigabeEntfernen(); print("permission \(kern.uuid): removed"); break }
        guard let m = args.first.flatMap({ $0 == "read-only" ? Modus.nurlesen : ($0 == "write" ? Modus.schreiben : nil) }) else { hilfe() }
        try kern.freigabeSetzen(m); print("permission \(kern.uuid): \(m == .nurlesen ? "read-only" : "write")")
    case "backup", "check":
        guard let m = finden(uuid: kern.uuid) else { throw Fehler.nichtGefunden(kern.uuid) }
        if einhaengungen()[m.geraet] != nil { throw Fehler.eingehaengt(m.geraet) }
        if let h = kern.helfer("freigeben", kern.uuid) { meldung("NOTE: helper: \(h)\n") }
        defer { _ = kern.helfer("zurueckgeben", kern.uuid) }
        if cmd == "backup" {
            let e = kern.ablage.einstellungen()
            let r = try metadatenSichern(quelle: m.rohgeraet, ort: opt("--path") ?? e.sicherungOrt, uuid: kern.uuid, anzahl: opt("--keep").flatMap(Int.init) ?? e.sicherungAnzahl, partitionsgroesse: m.groesse)
            print("backed up: \(r.ordner) (\(r.dateien) files)")
        } else {
            let r = try nachpruefung(pfad: m.rohgeraet, partitionsgroesse: m.groesse, tief: !flag("--no-catalog"))
            r.hinweise.forEach { print("NOTE: \($0)") }
            print(r.ok ? "CHECK OK (catalog: \(r.tiefe.rawValue))" : "CHECK FAILED: " + r.probleme.joined(separator: "; "))
            if !r.ok { exit(33) }
        }
    case "backup-location":
        var e = kern.ablage.einstellungen()
        if let p = args.first(where: { !$0.hasPrefix("-") }) { e.sicherungOrt = p; kern.ablage.einstellungenSetzen(e) }
        print(e.sicherungOrt.isEmpty ? "(not set; writing is locked until a location is chosen)" : e.sicherungOrt)
    case "copy-folder":
        guard args.count >= 2 else { hilfe() }
        let b = try kern.wegsichern(quelle: args[0], ziel: args[1])
        print(b.text); if !b.ok { exit(35) }
    case "speed":
        let r = try kern.tempoTesten(schreiben: flag("--write"))
        print(String(format: "%@: %.1f MB/s (%d files, %llu bytes)", r.art, r.mbProSekunde, r.dateien, r.bytes))
    case "access":
        if let f = kern.zugriffPruefen() { throw Fehler.helfer(f) }; print("access ok (no-effect probe)")
    case "backups": kern.sicherungen().forEach { print($0) }
    case "restore":
        guard let n = args.first, !n.hasPrefix("-") else { hilfe() }
        if flag("--execute") {
            let r = try kern.zurueckspielen(sicherung: n)
            print("restored; check afterwards: " + (r.ok ? "ok" : "ISSUES: " + r.probleme.joined(separator: "; ")))
        } else {
            let p = try kern.zurueckspielenProbe(sicherung: n)
            print(p.text); print("Dry run, nothing written. To write: --execute (everything written since the backup is lost)")
        }
    case "state":
        let m = kern.ablage.merker(kern.uuid)
        print(String(decoding: try JSONEncoder().encode(m), as: UTF8.self))
    case "log": kern.ablage.protokollLesen().forEach { print("\($0.zeit)  \($0.text)") }
    case "speed-history": kern.ablage.tempoVerlauf().forEach { print("\($0.zeit)  \($0.art)  \(String(format: "%.1f", $0.mbProSekunde)) MB/s") }
    case "drives": kern.ablage.einstellungen().drobos.forEach { print("\($0.uuid)  \($0.name)  \($0.rolle.rawValue)") }
    case "add-drive":
        guard args.count >= 2 else { hilfe() }
        var e = kern.ablage.einstellungen(); e.drobos.removeAll { $0.uuid == args[0].uppercased() }
        e.drobos.append(DroboEintrag(uuid: args[0], name: args[1], rolle: args.count > 2 && args[2] == "timemachine" ? .timemachine : .arbeitsvolume))
        kern.ablage.einstellungenSetzen(e); print("ok")
    case "helper":
        guard let a = args.first, a == "grant" || a == "release" else { hilfe() }
        if let f = helferAufruf(a == "grant" ? "freigeben" : "zurueckgeben", uuid: kern.uuid) { throw Fehler.helfer(f) }
        print("\(a) ok")
    case "uninstall":
        print("""
        To remove DroboDraft run: bash fskit_probe/tools/uninstall.sh   (add --data to delete settings, log and the module's permission list)
        It quits the app, unregisters the helper service and deletes /Applications/DroboFSProbe.app. You then switch off the module and the helper in
        System Settings (General > Login Items & Extensions) and remove the Full Disk Access entry for 'drobohelper' yourself.
        """)
    default: hilfe()
    }
} catch let f as Fehler {
    meldung("ERROR: \(f)\n"); exit(f.code)
} catch let f as AppFehler {
    meldung("ERROR: \(f)\n"); exit(f.code)
} catch {
    meldung("ERROR: \(error)\n"); exit(1)
}
