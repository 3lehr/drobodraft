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
    drobo speed [--size GB] [--cycles N] [--write]   read speed (large existing files); with --write a write+read cycle in .drobodraft_speedtest, only when mounted writable with a backup and 2x free space
    drobo hardware                             bays, capacity and status as reported by the Drobo (needs the optional status driver)
    drobo access                               check without effect whether the helper may reach the device
    drobo iscsi-probe [--write-test]           check a real iSCSI target (DroboPro): host from DROBO_ISCSI_HOST; reads only; --write-test writes one sector on LUN 1 only if LUN 1 is empty
    drobo iscsi-format --lun 1 --name NAME [--partition-gib N] [--target IQN] [--execute]
                                               set up LUN 1 of an iSCSI target (DroboPro test device) with GPT + one HFS+ partition (no journal); dry run without --execute
    drobo iscsi-write-test [--lba N] [--sizes 4096,262144]   write, read back and compare on LUN 1 of a test target; stops at the first error
    drobo iscsi-relay HOST                     ask the helper service for a loopback port that forwards to HOST:3260 (private IPv4 only)
    drobo iscsi-mount --host H --lun N [--write [--no-backup]] [--target IQN] [--mountpoint P]   mount a LUN (--write backs up the volume metadata first, to the location of "drobo backup-location") of a network target through the helper service (read-only unless --write); default mountpoint /private/tmp/drobo_iscsi_mntN
    drobo iscsi-unmount [--lun N] [--mountpoint P]
    drobo state | log | speed-history | drives
    drobo detect [--usb-only]                  find Drobos: connected via USB (SCSI vendor "Drobo") and in the local network (DroboPro, via the helper service); shows what is not set up yet
    drobo add-drive UUID NAME [timemachine] [--host H --lun N]   (--host/--lun: network drobo)
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
    let ohneDrobo: Set<String> = ["detect", "add-drive", "drives", "uninstall", "backup-location", "log", "speed-history", "iscsi-probe", "iscsi-format", "iscsi-write-test", "iscsi-relay", "iscsi-mount", "iscsi-unmount"]
    if kern.uuid.isEmpty && !ohneDrobo.contains(cmd) { throw Fehler.eingabe("No Drobo set up. Run 'drobo detect', then 'drobo add-drive UUID NAME' (or pass --uuid / set DROBO_UUID).") }
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
        guard let gb = opt("--size").map({ Double($0) ?? 0 }) ?? Optional(1.0), gb > 0 else { throw Fehler.eingabe("--size GB must be a number > 0") }
        let n = opt("--cycles").flatMap(Int.init) ?? 1
        let z = try kern.tempoLauf(schreiben: flag("--write"), groesse: UInt64(gb * 1e9), zyklen: n, zyklus: { z in
            for r in [z.schreiben, z.lesen].compactMap({ $0 }) { print(String(format: "%@: %.1f MB/s (%d files, %llu bytes)", r.art, r.mbProSekunde, r.dateien, r.bytes)) }
        })
        if z.isEmpty { throw AppFehler.tempotest("nothing measured") }
    case "hardware":
        guard let h = liesDroboStatus(uuid: kern.uuid) else { print("No status data (status driver not active?)"); exit(1) }
        print("\(h.modell)  firmware \(h.firmware) build \(h.firmwareBuild.map(String.init) ?? "-")  age \(Int(h.alter())) s  severity \(h.schwere)")
        if let k = h.kapazitaet { print(String(format: "capacity: free %.2f TB, used %.2f TB, protected total %.2f TB (%.1f%% free)", Double(k.frei) / 1e12, Double(k.benutzt) / 1e12, Double(k.gesamtGeschuetzt) / 1e12, k.freiAnteil * 100)) }
        h.schaechte.forEach { print("bay \($0.nr): \($0.farbe)  \($0.modell)  \(Double($0.kapazitaet) / 1e12) TB  errors \($0.fehler)") }
        h.meldungen.forEach { print("message [\($0.schwere)]: \($0.text)") }
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
    case "detect":
        let bekannt = Set(kern.ablage.einstellungen().drobos.map { $0.uuid })
        let r = drobosSuchen(lan: !flag("--usb-only"))
        let neu = r.usb.filter { !bekannt.contains($0.uuid) }
        if neu.isEmpty && r.lan.isEmpty { print("No new Drobo found.") }
        neu.forEach { print("USB  \($0.uuid)  \($0.name)  \($0.modell)  \($0.bsd)   -> drobo add-drive \($0.uuid) \"\($0.name.isEmpty ? "Drobo" : $0.name)\"") }
        for d in r.lan {
            if d.luns.isEmpty { print("LAN  \(d.host)  (Drobo found, no set-up volume)") }
            for l in d.luns { print("LAN  \(d.host)  LUN \(l.lun)  \(ByteCountFormatter.string(fromByteCount: Int64(l.partitionBytes), countStyle: .file))  \(l.uuid)\(bekannt.contains(l.uuid) ? "  (known)" : "   -> drobo add-drive \(l.uuid) DroboPro --host \(d.host) --lun \(l.lun)")") }
        }
        if let f = r.lanFehler { print("LAN search failed: \(f)") }
    case "add-drive":
        guard args.count >= 2 else { hilfe() }
        var e = kern.ablage.einstellungen(); e.drobos.removeAll { $0.uuid == args[0].uppercased() }
        e.drobos.append(DroboEintrag(uuid: args[0], name: args[1], rolle: args.count > 2 && args[2] == "timemachine" ? .timemachine : .arbeitsvolume,
                                     netz: opt("--host").flatMap { h in opt("--lun").flatMap(Int.init).map { NetzZiel(host: h, lun: $0) } }))
        kern.ablage.einstellungenSetzen(e); print("ok")
    case "helper":
        guard let a = args.first, a == "grant" || a == "release" else { hilfe() }
        if let f = helferAufruf(a == "grant" ? "freigeben" : "zurueckgeben", uuid: kern.uuid) { throw Fehler.helfer(f) }
        print("\(a) ok")
    case "iscsi-probe":
        guard let h = ProcessInfo.processInfo.environment["DROBO_ISCSI_HOST"], !h.isEmpty else { throw Fehler.eingabe("set DROBO_ISCSI_HOST to the target's address") }
        print(try iscsiSonde(host: h, port: ProcessInfo.processInfo.environment["DROBO_ISCSI_PORT"].flatMap { UInt16($0) } ?? 3260, schreibtest: flag("--write-test")))
    case "iscsi-write-test":     // Testgeraet: schreibt auf LUN 1 ab --lba (Vorgabe 16 Mi), je Groesse (Byte, Vorgabe 4096,262144,524288), liest zurueck und vergleicht
        guard let h = ProcessInfo.processInfo.environment["DROBO_ISCSI_HOST"], !h.isEmpty else { throw Fehler.eingabe("set DROBO_ISCSI_HOST to the target's address") }
        try iscsiSchreibprobe(host: h, ablba: opt("--lba").flatMap { UInt64($0) } ?? 16 << 20, groessen: (opt("--sizes") ?? "4096,262144,524288").split(separator: ",").compactMap { Int($0) }, meldung: { print($0) })
    case "iscsi-relay":      // Dienst-Weiterleitung 127.0.0.1:<Port> -> HOST:3260 anfordern und den lokalen Port ausgeben
        guard let h = args.first, !h.hasPrefix("-") else { hilfe() }
        print(try helferISCSIWeiterleitung(host: h))
    case "iscsi-mount":
        guard let h = opt("--host") ?? ProcessInfo.processInfo.environment["DROBO_ISCSI_HOST"] else { hilfe() }
        let e = kern.ablage.einstellungen()
        if flag("--all") {
            let r = try iscsiAlleEinhaengen(host: h, schreiben: flag("--write"), sicherung: e.sicherungOrt.isEmpty ? nil : (e.sicherungOrt, e.sicherungAnzahl), ohneSicherung: flag("--no-backup"), meldung: { print($0) })
            if r.values.contains(where: { $0 != nil }) { throw Fehler.eingabe("not every LUN could be mounted (see above)") }
            break
        }
        guard let l = opt("--lun").flatMap(Int.init) else { hilfe() }
        try iscsiEinhaengen(host: h, lun: l, schreiben: flag("--write"), ziel: opt("--target"), ort: opt("--mountpoint"), sicherung: e.sicherungOrt.isEmpty ? nil : (e.sicherungOrt, e.sicherungAnzahl),
                            ohneSicherung: flag("--no-backup"), meldung: { print($0) })
    case "iscsi-lunsize":     // GESPERRT (EA-Systembefehl startet die DroboPro neu, gemessen 2026-10-17): verweigert ohne Netzkontakt.
        try iscsiLunGroesse()
    case "iscsi-luns":      // alle LUNs: Groesse, Schema (Seite 07), HFS+-Partition, Einhaengung
        guard let h = opt("--host") ?? ProcessInfo.processInfo.environment["DROBO_ISCSI_HOST"] else { hilfe() }
        let mnt = Set(iscsiEingehaengteLuns())
        for l in try netzLunVerzeichnis(host: h) { print("LUN \(l.lun): \(l.groesse >> 30) GiB, scheme \(l.schema), " + (l.hatDateisystem ? "HFS+ partition \((l.partitionBytes ?? 0) >> 30) GiB" : "no file system") + (mnt.contains(l.lun) ? ", mounted" : "")) }
    case "iscsi-unmount":
        if flag("--all") { try iscsiAlleAushaengen(meldung: { print($0) }); break }
        try iscsiAushaengen(ort: opt("--mountpoint") ?? "\(iscsiVorgabeOrt)\(opt("--lun") ?? "1")"); print("unmounted")
    case "iscsi-format":
        let env = ProcessInfo.processInfo.environment
        guard let h = env["DROBO_ISCSI_HOST"], !h.isEmpty else { throw Fehler.eingabe("set DROBO_ISCSI_HOST to the target's address") }
        guard let w = env["DROBO_TESTDIR"], !w.isEmpty else { throw Fehler.eingabe("set DROBO_TESTDIR (work folder for the local HFS+ image, not the startup volume)") }
        guard let l = opt("--lun").flatMap(Int.init), let n = opt("--name") else { hilfe() }
        if flag("--execute") && opt("--confirm") != String(l) { throw Fehler.eingabe("--execute erases LUN \(l) completely: add --confirm \(l)") }
        try iscsiFormat(host: h, port: env["DROBO_ISCSI_PORT"].flatMap { UInt16($0) } ?? 3260, ziel: opt("--target"), lun: l, name: n,
                        partitionBytes: opt("--partition-gib").flatMap { UInt64($0) }.map { $0 << 30 }, ausfuehren: flag("--execute"), arbeitsordner: w, meldung: { print($0) })
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
