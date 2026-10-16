import XCTest
@testable import DroboKern

/// Alle Tests am Abbild (<= 64 MiB, unter $DROBO_TESTDIR). Nie ein Drobo-Geraet: gesucht wird nur nach der UUID des frischen Abbilds.
/// Die Freigabeliste des Betreibers wird nicht benutzt (Tests haben eine eigene Datei); tearDown belegt, dass sie byteweise unveraendert ist.
final class KernTests: XCTestCase {
    static let betreiberListe = NSHomeDirectory() + "/Library/Containers/\(modulKennung)/Data/freigabe.json"
    var vorher: Data?
    var dir = ""
    var geraete: [String] = []      // von uns angehaengte Abbild-Geraete
    var orte: [String] = []         // von uns eingehaengte Orte
    var erlaubt = false             // Integrationstest schreibt absichtlich in die echte Liste

    override func setUpWithError() throws {
        vorher = FileManager.default.contents(atPath: Self.betreiberListe)
        // Abbilder und Sicherungsorte brauchen ein Laufwerk, das nicht das Startvolume ist (sonst lehnt die Sicherung den Ort ab).
        guard let base = Kern.umgebung("DROBO_TESTDIR") else { throw XCTSkip("DROBO_TESTDIR nicht gesetzt: Ordner auf einem Nicht-Startvolume fuer Test-Abbilder") }
        dir = "\(base)/\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for o in orte.reversed() { if ausfuehren("/sbin/umount", [o]).0 != 0 { ausfuehren("/usr/sbin/diskutil", ["unmount", "force", o]) } }
        for g in geraete.reversed() { ausfuehren("/usr/bin/hdiutil", ["detach", g, "-force"]) }
        try? FileManager.default.removeItem(atPath: dir)
        if erlaubt, let v = vorher { try? v.write(to: URL(fileURLWithPath: Self.betreiberListe)) }   // Test hat sie absichtlich veraendert: zurueckstellen, danach belegen
        XCTAssertEqual(FileManager.default.contents(atPath: Self.betreiberListe), vorher, "Betreiber-Freigabeliste nicht unveraendert")
    }

    // MARK: Hilfen

    /// Frisches journaled HFS+-Abbild mit Marker (damit das Modul es annimmt); gibt den Pfad zurueck.
    func abbild(_ name: String, journal: Bool = true, marker: Bool = true) throws -> String {
        let f = "\(dir)/\(name).img"
        XCTAssertEqual(ausfuehren("/usr/bin/truncate", ["-s", "64m", f]).0, 0)
        let dev = try anhaengen(f)
        let (rc, out) = ausfuehren("/sbin/newfs_hfs", (journal ? ["-J"] : []) + ["-v", "KERNTEST", "/dev/r" + dev.dropFirst(5)])
        XCTAssertEqual(rc, 0, out)
        ausfuehren("/usr/bin/hdiutil", ["detach", dev])
        geraete.removeAll { $0 == dev }
        if marker { let h = try FileHandle(forWritingTo: URL(fileURLWithPath: f)); try h.write(contentsOf: Data("DROBOFSPROBE".utf8)); try h.close() }
        return f
    }

    func anhaengen(_ f: String) throws -> String {
        let (rc, out) = ausfuehren("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", f])
        XCTAssertEqual(rc, 0, out)
        let dev = String(out.split(separator: "\n").first!.split(separator: " ").first!)
        let (_, info) = ausfuehren("/usr/sbin/diskutil", ["info", dev])
        XCTAssertTrue(info.contains("Protocol:                 Disk Image") || info.contains("Disk Image"), "kein Disk-Image-Geraet: \(dev)")
        geraete.append(dev)
        return dev
    }

    /// Oracle: Volume-UUID laut diskutil (unabhaengig von DroboKern).
    func uuid(_ dev: String) throws -> String {
        let (_, out) = ausfuehren("/usr/sbin/diskutil", ["info", "-plist", dev])
        let p = try PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as! [String: Any]
        return (p["VolumeUUID"] as! String).uppercased()
    }

    func freigabe(_ eintraege: [[String: Any]]) throws -> String {
        let p = "\(dir)/freigabe.json"
        try JSONSerialization.data(withJSONObject: eintraege).write(to: URL(fileURLWithPath: p)); return p
    }

    func kern(_ u: String, _ f: String, modul: ModulStatus = ModulStatus(installiert: true, freigeschaltet: true)) -> Kern {
        var k = Kern(uuid: u, freigabePfad: f, modul: { modul }); k.ablage = testAblage(); return k
    }

    /// Eigene Datenablage je Test (nie die des Betreibers); Sicherungsort im Testordner.
    func testAblage(anzahl: Int = 2) -> Datenablage {
        let a = Datenablage(ordner: "\(dir)/daten")
        var e = a.einstellungen(); e.sicherungOrt = "\(dir)/sicherungen"; e.sicherungAnzahl = anzahl
        a.einstellungenSetzen(e); return a
    }

    func eintrag(_ u: String, _ m: String) -> [String: Any] { ["volume_uuid": u, "modus": m, "max_bytes": 1 << 40] }

    func kopieMitBits(_ f: String, nach: String, _ patch: (FileHandle) throws -> Void) throws -> String {
        let n = "\(dir)/\(nach).img"
        try FileManager.default.copyItem(atPath: f, toPath: n)
        let h = try FileHandle(forUpdating: URL(fileURLWithPath: n)); try patch(h); try h.close()
        return n
    }

    // MARK: Torpruefungen (an Abbilddateien, ohne Geraet)

    func testTorSauber() throws {
        let t = try torpruefung(pfad: try abbild("sauber"))
        XCTAssertTrue(t.ok, "\(t.probleme)")
        XCTAssertEqual(t.signatur, "H+"); XCTAssertTrue(t.attr & 0x100 != 0); XCTAssertTrue(t.attr & 0x2000 != 0)
        XCTAssertTrue(t.journal.hasSuffix("leer"), t.journal)
    }

    func testTorBit0x800GesetztWirdAbgelehnt() throws {
        let f = try abbild("a")
        let k = try kopieMitBits(f, nach: "b800") { h in
            try h.seek(toOffset: 1024 + 4); var a = try XCTUnwrap(try h.read(upToCount: 4)); a[a.startIndex + 2] |= 0x08  // attr bit 0x0800
            try h.seek(toOffset: 1024 + 4); try h.write(contentsOf: a)
        }
        let t = try torpruefung(pfad: k)
        XCTAssertFalse(t.ok); XCTAssertTrue(t.probleme.contains { $0.contains("0x800") }, "\(t.probleme)")
    }

    func testTorBit0x4000GesetztWirdAbgelehnt() throws {
        let k = try kopieMitBits(try abbild("a"), nach: "b4000") { h in
            try h.seek(toOffset: 1024 + 4); var a = try XCTUnwrap(try h.read(upToCount: 4)); a[a.startIndex + 2] |= 0x40
            try h.seek(toOffset: 1024 + 4); try h.write(contentsOf: a)
        }
        XCTAssertTrue(try torpruefung(pfad: k).probleme.contains { $0.contains("0x4000") })
    }

    func testTorBit0x100FehltWirdAbgelehnt() throws {
        let k = try kopieMitBits(try abbild("a"), nach: "b100") { h in
            try h.seek(toOffset: 1024 + 4); var a = try XCTUnwrap(try h.read(upToCount: 4)); a[a.startIndex + 2] &= ~0x01
            try h.seek(toOffset: 1024 + 4); try h.write(contentsOf: a)
        }
        XCTAssertTrue(try torpruefung(pfad: k).probleme.contains { $0.contains("0x100") })
    }

    func testTorJournalNichtLeerWirdAbgelehnt() throws {
        let f = try abbild("a")
        let k = try kopieMitBits(f, nach: "jnl") { h in
            // Journal-Info-Block -> Journal-Offset -> Header.start (LE, +8) auf 512 setzen; JIB-Flag "needs init" (Bit 4) vorher loeschen, falls gesetzt
            try h.seek(toOffset: 1024); let vh = try XCTUnwrap(try h.read(upToCount: 512))
            let be: (Int, Int) -> UInt64 = { o, n in vh[vh.startIndex + o ..< vh.startIndex + o + n].reduce(0) { $0 << 8 | UInt64($1) } }
            let jibOff = be(12, 4) * be(40, 4)
            try h.seek(toOffset: jibOff); var jib = try XCTUnwrap(try h.read(upToCount: 512))
            jib[jib.startIndex + 3] &= ~0x04
            try h.seek(toOffset: jibOff); try h.write(contentsOf: jib)
            let jOff = jib[jib.startIndex + 36 ..< jib.startIndex + 44].reduce(0) { $0 << 8 | UInt64($1) }
            try h.seek(toOffset: jOff + 8); try h.write(contentsOf: Data([0x00, 0x02, 0, 0, 0, 0, 0, 0]))  // start = 512 (LE), end bleibt 0 -> ungleich
        }
        let t = try torpruefung(pfad: k)
        XCTAssertFalse(t.ok); XCTAssertTrue(t.probleme.contains { $0.contains("Journal") }, "\(t.probleme) \(t.journal)")
    }

    func testTorKeineSignaturUndUnlesbar() throws {
        let leer = "\(dir)/leer.img"; FileManager.default.createFile(atPath: leer, contents: Data(count: 8192))
        XCTAssertTrue(try torpruefung(pfad: leer).probleme.first!.contains("kein HFS+"))
        XCTAssertThrowsError(try torpruefung(pfad: "\(dir)/gibtsnicht")) { XCTAssertEqual(($0 as? Fehler)?.code, 15) }
    }

    // MARK: Freigabeliste

    func testFreigabeLesenSetzenBehaeltAndereEintraege() throws {
        let u = "AAAAAAAA-0000-0000-0000-000000000001", fremd = "BBBBBBBB-0000-0000-0000-000000000002"
        let p = try freigabe([eintrag(fremd, "nurlesen")])
        XCTAssertNil(try Freigabe.lesen(uuid: u, pfad: p))
        try Freigabe.setzen(uuid: u.lowercased(), modus: .nurlesen, maxBytes: 123, pfad: p)
        XCTAssertEqual(try Freigabe.lesen(uuid: u, pfad: p), .nurlesen)
        try Freigabe.setzen(uuid: u, modus: .schreiben, maxBytes: nil, pfad: p)
        XCTAssertEqual(try Freigabe.lesen(uuid: u, pfad: p), .schreiben)
        XCTAssertEqual(try Freigabe.lesen(uuid: fremd, pfad: p), .nurlesen)
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as! [[String: Any]]
        XCTAssertEqual(j.count, 2); XCTAssertEqual(j.first { ($0["volume_uuid"] as? String) == u }?["max_bytes"] as? Int, 123)
    }

    func testFreigabeNeuerEintragOhneGroesseUndKaputteDatei() throws {
        let p = try freigabe([])
        XCTAssertThrowsError(try Freigabe.setzen(uuid: "X", modus: .nurlesen, maxBytes: nil, pfad: p)) { XCTAssertEqual(($0 as? Fehler)?.code, 21) }
        let kaputt = "\(dir)/kaputt.json"; try Data("{nicht json".utf8).write(to: URL(fileURLWithPath: kaputt))
        XCTAssertThrowsError(try Freigabe.setzen(uuid: "X", modus: .nurlesen, maxBytes: 1, pfad: kaputt))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: kaputt)), Data("{nicht json".utf8), "kaputte Datei darf nicht ueberschrieben werden")
    }

    func testFreigabeDictFormatBleibtDict() throws {
        let p = "\(dir)/d.json"; try JSONSerialization.data(withJSONObject: ["eintraege": [eintrag("A", "nurlesen")]]).write(to: URL(fileURLWithPath: p))
        try Freigabe.setzen(uuid: "A", modus: .schreiben, maxBytes: nil, pfad: p)
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as! [String: Any]
        XCTAssertEqual((j["eintraege"] as! [[String: Any]]).first?["modus"] as? String, "schreiben")
    }

    // MARK: Finden und Zustaende

    func testFindenPerUUIDundFalscheUUID() throws {
        let dev = try anhaengen(try abbild("f"))
        let u = try uuid(dev)
        let m = try XCTUnwrap(finden(uuid: u))
        XCTAssertEqual(m.geraet, dev); XCTAssertEqual(m.groesse, 64 << 20)
        XCTAssertNil(finden(uuid: "DEADBEEF-0000-0000-0000-00000000DEAD"))
        XCTAssertNotNil(finden(uuid: u.lowercased()))
    }

    func testZustandNichtAngeschlossenUndAngeschlossen() throws {
        let f = try abbild("z"); let fp = try freigabe([])
        let z0 = try kern("DEADBEEF-0000-0000-0000-00000000DEAD", fp).zustand()
        guard case .nichtAngeschlossen = z0.verbindung else { return XCTFail("\(z0.kurz)") }
        XCTAssertEqual(z0.kurz, "nicht angeschlossen"); XCTAssertNil(z0.freigabe)
        let u = try uuid(try anhaengen(f))
        let z1 = try kern(u, try freigabe([eintrag(u, "nurlesen")])).zustand()
        guard case .angeschlossen = z1.verbindung else { return XCTFail("\(z1.kurz)") }
        XCTAssertEqual(z1.kurz, "angeschlossen, nicht eingehaengt"); XCTAssertEqual(z1.freigabe, .nurlesen)
        XCTAssertEqual(z1.json["verbindung"] as? String, "angeschlossen")
    }

    func testModulStatusSpiegeltPluginkit() throws {
        let (_, out) = ausfuehren("/usr/bin/pluginkit", ["-m", "-i", modulKennung])
        let s = modulStatus()
        XCTAssertEqual(s.installiert, out.contains(modulKennung))
        XCTAssertEqual(s.freigeschaltet, out.trimmingCharacters(in: .whitespaces).hasPrefix("+"))
        let z = try kern("DEADBEEF-0000-0000-0000-00000000DEAD", try freigabe([]), modul: ModulStatus(installiert: true, freigeschaltet: false)).zustand()
        XCTAssertTrue(z.text.contains("NICHT freigeschaltet"))
    }

    /// Kernel-Mount ro und rw am Abbild (mount -t hfs, -r fuer ro; mount_hfs kennt "-o rdonly" nicht): Zustand muss "durch Kernel" und ro/rw melden.
    func testZustandEingehaengtDurchKernelRoUndRw() throws {
        // ohne Journal: ein frisch mit -J formatiertes Volume ("needs init") laesst sich nicht read-only einhaengen (Kernel: EINVAL, Modul: EPERM; Messung 2026-10-15)
        let dev = try anhaengen(try abbild("k", journal: false)); let u = try uuid(dev)
        let k = kern(u, try freigabe([eintrag(u, "nurlesen")]))
        for (opt, ro) in [(["-r"], true), ([String](), false)] {
            let mp = "\(dir)/kmnt_\(ro)"; try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
            let (rc, out) = ausfuehren("/sbin/mount", ["-t", "hfs"] + opt + [dev, mp]); XCTAssertEqual(rc, 0, out)
            orte.append(mp)
            let z = try k.zustand()
            XCTAssertEqual(z.kurz, "eingehaengt \(ro ? "ro" : "rw") durch Kernel", z.text)
            guard case .eingehaengt(_, let e) = z.verbindung else { return XCTFail() }
            XCTAssertEqual(e.nurlesen, ro); XCTAssertEqual(e.treiber, .kernel)
            // eingehaengt -> einhaengen abgelehnt
            XCTAssertThrowsError(try k.einhaengen(ort: "/private/tmp/drobo_kerntest_x")) { XCTAssertEqual(($0 as? Fehler)?.code, 11) }
            XCTAssertEqual(ausfuehren("/sbin/umount", [mp]).0, 0); orte.removeAll { $0 == mp }
        }
    }

    // MARK: einhaengen: Ablehnungen (Negativfaelle)

    func testEinhaengenAblehnungen() throws {
        let f = try abbild("e"); let dev = try anhaengen(f); let u = try uuid(dev)
        let ort = "/private/tmp/drobo_kerntest_\(UUID().uuidString.prefix(8))"
        func code(_ k: Kern, modus: Modus = .nurlesen, ort o: String? = nil) -> Int32? {
            do { try k.einhaengen(modus: modus, ort: o ?? ort); return 0 } catch { return (error as? Fehler)?.code }
        }
        // falsche UUID
        XCTAssertEqual(code(kern("DEADBEEF-0000-0000-0000-00000000DEAD", try freigabe([eintrag("DEADBEEF-0000-0000-0000-00000000DEAD", "nurlesen")]))), 10)
        // fehlende Freigabe (Abbild traegt den Marker, das Modul wuerde es annehmen: die CLI lehnt trotzdem ab)
        XCTAssertEqual(code(kern(u, try freigabe([eintrag("AAAAAAAA-0000-0000-0000-000000000001", "nurlesen")]))), 12)
        // Schreiben bei Freigabe nurlesen
        XCTAssertEqual(code(kern(u, try freigabe([eintrag(u, "nurlesen")])), modus: .schreiben), 13)
        // Modul nicht freigeschaltet / nicht installiert
        XCTAssertEqual(code(kern(u, try freigabe([eintrag(u, "nurlesen")]), modul: ModulStatus(installiert: true, freigeschaltet: false))), 14)
        XCTAssertEqual(code(kern(u, try freigabe([eintrag(u, "nurlesen")]), modul: ModulStatus(installiert: false, freigeschaltet: false))), 14)
        // Ort unter $HOME (auch ueber ".." und nicht vorhandene Unterordner)
        XCTAssertEqual(code(kern(u, try freigabe([eintrag(u, "nurlesen")])), ort: NSHomeDirectory() + "/Desktop/drobo_mnt"), 17)
        XCTAssertEqual(code(kern(u, try freigabe([eintrag(u, "nurlesen")])), ort: "/private/tmp/../../" + NSHomeDirectory() + "/x"), 17)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Desktop/drobo_mnt"), "Ablehnung darf keinen Ordner anlegen")
        // nicht eingehaengt -> aushaengen
        XCTAssertThrowsError(try kern(u, try freigabe([])).aushaengen()) { XCTAssertEqual(($0 as? Fehler)?.code, 19) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ort), "Ablehnungen duerfen keinen Einhaengeort anlegen")
    }

    func testEinhaengenTorBit0x800Abbild() throws {
        let k0 = try abbild("g")
        let bad = try kopieMitBits(k0, nach: "g800") { h in
            try h.seek(toOffset: 1024 + 4); var a = try XCTUnwrap(try h.read(upToCount: 4)); a[a.startIndex + 2] |= 0x08
            try h.seek(toOffset: 1024 + 4); try h.write(contentsOf: a)
        }
        let dev = try anhaengen(bad); let u = try uuid(dev)
        let ort = "/private/tmp/drobo_kerntest_\(UUID().uuidString.prefix(8))"
        XCTAssertThrowsError(try kern(u, try freigabe([eintrag(u, "nurlesen")])).einhaengen(ort: ort)) {
            XCTAssertEqual(($0 as? Fehler)?.code, 15); XCTAssertTrue("\($0)".contains("0x800"), "\($0)")
        }
        XCTAssertNil(einhaengungen()[dev], "Tor-Ablehnung darf nichts einhaengen")
    }

    // MARK: einhaengen: Erfolg ueber das Modul (nur wenn das Modul freigeschaltet ist)

    func ort() -> String { let o = "/private/tmp/drobo_kerntest_\(UUID().uuidString.prefix(8))"; orte.append(o); return o }

    /// Marker-Abbild: das Modul nimmt es als "schreiben" an (Modul-Gate), ein "-o rdonly"-Mount scheitert dort (Messung 2026-10-15, siehe Befund); rw geht.
    func testEinhaengenSchreibenAushaengenDurchHfsdroboMarkerAbbild() throws {
        try XCTSkipUnless(modulStatus().freigeschaltet, "Modul nicht freigeschaltet")
        let dev = try anhaengen(try abbild("m")); let u = try uuid(dev)
        let k = kern(u, try freigabe([eintrag(u, "schreiben")]))
        let o = ort()
        let e = try k.einhaengen(modus: .schreiben, ort: o)
        XCTAssertFalse(e.nurlesen); XCTAssertEqual(e.treiber, .hfsdrobo)
        XCTAssertEqual(eigeneSicherungen(ort: "\(dir)/sicherungen", uuid: u).count, 1, "rw ohne Sicherung")
        XCTAssertTrue(k.ablage.merker(u).rwAktiv)
        XCTAssertEqual(try k.zustand().kurz, "eingehaengt rw durch hfsdrobo")
        XCTAssertThrowsError(try k.einhaengen(modus: .schreiben, ort: o)) { XCTAssertEqual(($0 as? Fehler)?.code, 11) }
        // Schreib-Tempotest: nur rw + Sicherung; fehlt die Sicherung, wird abgelehnt
        let ok = try k.tempoTesten(schreiben: true, mib: 4); XCTAssertEqual(ok.art, "schreiben")
        let sich = k.ablage.merker(u).letzteSicherung
        k.ablage.merkerAendern(u) { $0.letzteSicherung = nil }
        XCTAssertThrowsError(try k.tempoTesten(schreiben: true)) { XCTAssertTrue("\($0)".contains("Metadaten-Sicherung"), "\($0)") }
        k.ablage.merkerAendern(u) { $0.letzteSicherung = sich; $0.rwAktiv = false }
        XCTAssertThrowsError(try k.tempoTesten(schreiben: true)) { XCTAssertTrue("\($0)".contains("Einhaengen zum Schreiben"), "\($0)") }
        k.ablage.merkerAendern(u) { $0.rwAktiv = true }
        let pr = try k.aushaengen()
        XCTAssertEqual(try k.zustand().kurz, "angeschlossen, nicht eingehaengt")
        XCTAssertEqual(pr?.ok, true, "\(String(describing: pr?.probleme))"); XCTAssertEqual(k.ablage.merker(u).letztePruefung?.ok, true)
        XCTAssertFalse(k.ablage.merker(u).rwAktiv)
    }

    /// Abbild OHNE Marker: das Modul entscheidet nur nach seiner Freigabeliste (echte Datei im Container; sie wird hier absichtlich ergaenzt und im tearDown byteweise zurueckgestellt).
    func testEinhaengenNurlesenDurchHfsdroboMitEchterFreigabe() throws {
        try XCTSkipUnless(modulStatus().freigeschaltet, "Modul nicht freigeschaltet")
        try XCTSkipUnless(vorher != nil, "Container fuer die Shell gesperrt (App-Daten-Schutz, kTCCServiceSystemPolicyAppData): Liste nur ueber den Hilfsdienst les-/schreibbar -> Ersatz: Integrationslauf CLI+Dienst (signierte CLI)")
        erlaubt = true
        let dev = try anhaengen(try abbild("n", journal: false, marker: false)); let u = try uuid(dev)
        let k = Kern(uuid: u, freigabePfad: Self.betreiberListe)
        XCTAssertThrowsError(try k.einhaengen(ort: ort())) { XCTAssertEqual(($0 as? Fehler)?.code, 12) }   // noch kein Eintrag
        try k.freigabeSetzen(.nurlesen)
        XCTAssertEqual(try Freigabe.lesen(uuid: u, pfad: Self.betreiberListe), .nurlesen)
        let o = ort()
        let e = try k.einhaengen(ort: o)
        XCTAssertTrue(e.nurlesen); XCTAssertEqual(e.treiber, .hfsdrobo)
        XCTAssertEqual(try k.zustand().kurz, "eingehaengt ro durch hfsdrobo")
        XCTAssertThrowsError(try k.einhaengen(modus: .schreiben, ort: o)) { XCTAssertEqual(($0 as? Fehler)?.code, 11) }
        try k.aushaengen()
        XCTAssertThrowsError(try k.einhaengen(modus: .schreiben, ort: ort())) { XCTAssertEqual(($0 as? Fehler)?.code, 13) }   // Eintrag nurlesen
    }
}
