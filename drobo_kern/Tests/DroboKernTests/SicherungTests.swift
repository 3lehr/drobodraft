import XCTest
@testable import DroboKern

/// Metadaten-Sicherung, Nachpruefung, Merker/Abziehen, Wegsichern, Tempo. Alles an Abbildern oder Testordnern unter /Volumes/daten/xcode/drobo/kerntest.
extension KernTests {
    var sicherOrt: String { "\(dir)/sicherungen" }
    func lies(_ p: String) -> Data { FileManager.default.contents(atPath: p) ?? Data() }
    func patch(_ f: String, _ off: UInt64, _ bytes: [UInt8]) throws {
        let h = try FileHandle(forUpdating: URL(fileURLWithPath: f)); try h.seek(toOffset: off); try h.write(contentsOf: Data(bytes)); try h.close()
    }
    func summen(_ ordner: String) -> [String: String] {
        var m: [String: String] = [:]
        for z in String(decoding: lies(ordner + "/SHA256SUMS"), as: UTF8.self).split(separator: "\n") { let t = z.components(separatedBy: "  "); m[t[1]] = t[0] }
        return m
    }

    // MARK: Metadaten-Sicherung

    func testSicherungInhaltGleichPythonWerkzeug() throws {
        let f = try abbild("s", journal: false, marker: false)
        let r = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2)
        XCTAssertTrue(sicherungPruefen(ordner: r.ordner).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.ordner + "/" + markerName))
        // Gegenprobe: Kopf/Ende gleich den Abbildbytes (unabhaengig vom Kern gelesen)
        let abb = lies(f)
        XCTAssertEqual(lies(r.ordner + "/kopf_1MiB.bin"), abb.prefix(1 << 20))
        XCTAssertEqual(lies(r.ordner + "/ende_1MiB.bin"), abb.suffix(1 << 20))
        // Orakel: das Python-Werkzeug erzeugt dieselben Fork-Dateien
        let py = "\(dir)/py"
        let (rc, out) = ausfuehren("/opt/homebrew/bin/python3", ["-I", "/Volumes/daten/Begod2026/drobo-nas/apps/drobo-nas/tools/hfs_attr_diagnose.py", f, "--sichern", py])
        try XCTSkipIf(rc != 0 && !FileManager.default.fileExists(atPath: py + "/SHA256SUMS"), "Python-Orakel nicht lauffaehig: \(out.suffix(200))")
        var a = summen(r.ordner), b = summen(py); a["extents.json"] = nil; b["extents.json"] = nil
        XCTAssertEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 6)
    }

    func testSicherungFehlerBeimPruefenLiefertKeineSicherung() throws {
        let f = try abbild("s", journal: false, marker: false)
        XCTAssertThrowsError(try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2, vorPruefung: { try? self.patch($0 + "/catalog.bin", 5, [0xEE]) })) {
            XCTAssertEqual(($0 as? AppFehler)?.code, 32, "\($0)")
        }
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: sicherOrt)).count, 0, "verfaelschte Sicherung darf nicht stehen bleiben")
    }

    /// Drobo-Geometrie: 64-KiB-Bloecke, Volumegroesse kein Vielfaches der Blockgroesse (Rest 24576 B hinter dem letzten Block).
    func testSicherungVolumeEndeNichtBlockausgerichtGleichPython() throws {
        let f = "\(dir)/schief.img"
        XCTAssertEqual(ausfuehren("/usr/bin/truncate", ["-s", String(64 * 1024 * 1024 + 24576), f]).0, 0)
        let dev = try anhaengen(f)
        XCTAssertEqual(ausfuehren("/sbin/newfs_hfs", ["-b", "65536", "-v", "SCHIEF", "/dev/r" + dev.dropFirst(5)]).0, 0)
        ausfuehren("/usr/bin/hdiutil", ["detach", dev]); geraete.removeAll { $0 == dev }
        let size = UInt64(lies(f).count); XCTAssertEqual(size % 65536, 24576)
        let r = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2)
        XCTAssertEqual(lies(r.ordner + "/ende_1MiB.bin"), lies(f).suffix(1 << 20))
        let meta = try JSONSerialization.jsonObject(with: lies(r.ordner + "/extents.json")) as! [String: Any]
        XCTAssertEqual(((meta["ende"] as! [String: Any])["volumeOffset"] as! NSNumber).uint64Value, size - (1 << 20))
        XCTAssertTrue(sicherungPruefen(ordner: r.ordner).isEmpty)
        let py = "\(dir)/py"
        let (rc, out) = ausfuehren("/opt/homebrew/bin/python3", ["-I", "/Volumes/daten/Begod2026/drobo-nas/apps/drobo-nas/tools/hfs_attr_diagnose.py", f, "--sichern", py])
        try XCTSkipIf(rc != 0 && !FileManager.default.fileExists(atPath: py + "/SHA256SUMS"), "Python-Orakel nicht lauffaehig: \(out.suffix(200))")
        var a = summen(r.ordner), b = summen(py); a["extents.json"] = nil; b["extents.json"] = nil
        XCTAssertEqual(a, b)
        XCTAssertEqual(a["ende_1MiB.bin"], b["ende_1MiB.bin"])
    }

    func testSicherungVerfaelschtWirdErkannt() throws {
        let f = try abbild("s", journal: false, marker: false)
        let r = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2)
        try patch(r.ordner + "/catalog.bin", 100, [0xEE])
        XCTAssertTrue(sicherungPruefen(ordner: r.ordner).contains { $0.contains("catalog.bin") })
        try FileManager.default.removeItem(atPath: r.ordner + "/SHA256SUMS")
        XCTAssertFalse(sicherungPruefen(ordner: r.ordner).isEmpty)
    }

    func testSicherungOrtSystemplatteUndDroboAbgelehnt() throws {
        let f = try abbild("s", journal: false, marker: false)
        for ort in [NSTemporaryDirectory() + "drobo_sichtest", NSHomeDirectory() + "/Desktop/drobo_sichtest", "relativ/pfad"] {
            XCTAssertThrowsError(try metadatenSichern(quelle: f, ort: ort, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2), ort) {
                XCTAssertEqual(($0 as? AppFehler)?.code, 30, "\($0)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: ort), "Ablehnung darf nichts anlegen")
        }
        // Ort auf der Drobo selbst (hier: das Abbild-Volume per Kernel eingehaengt)
        let dev = try anhaengen(try abbild("d", journal: false, marker: false))
        let mp = "\(dir)/dmnt"; try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        XCTAssertEqual(ausfuehren("/sbin/mount", ["-t", "hfs", dev, mp]).0, 0); orte.append(mp)
        XCTAssertThrowsError(try sicherungsOrtPruefen(mp + "/s", quelle: "/dev/r" + dev.dropFirst(5))) { XCTAssertEqual(($0 as? AppFehler)?.code, 30) }
    }

    func testSicherungPlatzMangelSchreibtNichts() throws {
        let f = try abbild("s", journal: false, marker: false)
        XCTAssertThrowsError(try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2, freiBytes: 1 << 20)) {
            XCTAssertEqual(($0 as? AppFehler)?.code, 31, "\($0)")
        }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: sicherOrt))?.count ?? 0, 0)
        // Grenze: genau benoetigt reicht, eins weniger nicht
        let ok = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 5, freiBytes: UInt64.max)
        let need = ok.bytes
        XCTAssertThrowsError(try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 5, freiBytes: need - 1, jetzt: Date().addingTimeInterval(5)))
        XCTAssertNoThrow(try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 5, freiBytes: need, jetzt: Date().addingTimeInterval(10)))
    }

    func testSicherungAufbewahrungLoeschtNurEigeneAelteste() throws {
        let f = try abbild("s", journal: false, marker: false)
        let u = "AAAAAAAA-0000-0000-0000-000000000001"
        let fm = FileManager.default; try fm.createDirectory(atPath: sicherOrt, withIntermediateDirectories: true)
        // fremde Ordner: gleiches Namensmuster OHNE Marker, andere UUID MIT Marker
        try fm.createDirectory(atPath: "\(sicherOrt)/\(u)_20000101-000000", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(sicherOrt)/BBBBBBBB-0000-0000-0000-000000000002_20000101-000000", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(sicherOrt)/BBBBBBBB-0000-0000-0000-000000000002_20000101-000000/" + markerName, contents: Data())
        var ordner: [String] = []
        for i in 0..<4 { ordner.append(try metadatenSichern(quelle: f, ort: sicherOrt, uuid: u, anzahl: 2, jetzt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60)).ordner) }
        let rest = eigeneSicherungen(ort: sicherOrt, uuid: u).map { "\(sicherOrt)/\($0)" }
        XCTAssertEqual(rest, Array(ordner.suffix(2)))
        XCTAssertTrue(fm.fileExists(atPath: "\(sicherOrt)/\(u)_20000101-000000"), "Ordner ohne Marker geloescht")
        XCTAssertTrue(fm.fileExists(atPath: "\(sicherOrt)/BBBBBBBB-0000-0000-0000-000000000002_20000101-000000"), "fremde UUID geloescht")
        // anzahl 0 darf die letzte nie loeschen
        let n = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: u, anzahl: 0, jetzt: Date(timeIntervalSince1970: 1_800_001_000))
        XCTAssertEqual(eigeneSicherungen(ort: sicherOrt, uuid: u).count, 1); XCTAssertTrue(fm.fileExists(atPath: n.ordner))
    }

    /// Synthetisches Volume mit Attribut-Fork, dessen zweiter Extent NUR im Extents-Overflow-Baum steht.
    func testSicherungUeberlaufExtents() throws {
        let bs = 4096, f = "\(dir)/ueberlauf.img"
        var img = [UInt8](repeating: 0, count: 8 << 20)
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { img[o + i] = UInt8(v >> UInt32(24 - 8 * i) & 0xFF) } }
        func put64(_ o: Int, _ v: UInt64) { put32(o, UInt32(v >> 32)); put32(o + 4, UInt32(v & 0xFFFFFFFF)) }
        func forkAt(_ o: Int, logical: UInt64, blocks: UInt32, ext: [(UInt32, UInt32)]) {
            put64(o, logical); put32(o + 12, blocks); for (i, e) in ext.enumerated() { put32(o + 16 + 8 * i, e.0); put32(o + 20 + 8 * i, e.1) }
        }
        img[1024] = 0x48; img[1025] = 0x2B; put32(1024 + 4, 0x100); put32(1024 + 40, UInt32(bs)); put32(1024 + 44, 2048); put32(1024 + 48, 2000)
        forkAt(1024 + 112, logical: 4096, blocks: 1, ext: [(10, 1)])
        forkAt(1024 + 192, logical: 8192, blocks: 2, ext: [(20, 2)])
        forkAt(1024 + 272, logical: 4096, blocks: 1, ext: [(40, 1)])
        forkAt(1024 + 352, logical: 8192, blocks: 2, ext: [(30, 1)])
        // Extents-Baum: Knoten 0 = Header (firstLeaf 1, nodeSize 4096), Knoten 1 = Blatt mit einem Satz fuer fileID 8 ab Block 1
        let n0 = 20 * bs, n1 = 21 * bs
        img[n0 + 8] = 1; put32(n0 + 14 + 10, 1); img[n0 + 14 + 18] = 0x10; img[n0 + 14 + 19] = 0x00
        img[n1 + 8] = 0xFF; img[n1 + 11] = 1
        var r = n1 + 14; img[r + 1] = 10; img[r + 2] = 0; put32(r + 4, 8); put32(r + 8, 1)
        r += 12; put32(r, 31); put32(r + 4, 1)
        img[n1 + bs - 1] = 14   // Satzoffset 14
        for (blk, v) in [(30, 0xA1), (31, 0xB2), (40, 0xC3), (10, 0xD4)] { for i in 0..<bs { img[blk * bs + i] = UInt8(v) } }
        img[(8 << 20) - 1024] = 0x48; img[(8 << 20) - 1023] = 0x2B
        try Data(img).write(to: URL(fileURLWithPath: f))
        let r2 = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2)
        let a = lies(r2.ordner + "/attributes.bin")
        XCTAssertEqual(a.count, 8192)
        XCTAssertEqual(a.prefix(4096), Data(repeating: 0xA1, count: 4096)); XCTAssertEqual(a.suffix(4096), Data(repeating: 0xB2, count: 4096), "Overflow-Extent nicht gelesen")
        // Abdeckung: wuerde der Overflow-Satz fehlen, bricht die Sicherung ab statt zu verkuerzen
        var kaputt = img; kaputt[n1 + 11] = 0
        let g = "\(dir)/ueberlauf2.img"; try Data(kaputt).write(to: URL(fileURLWithPath: g))
        XCTAssertThrowsError(try metadatenSichern(quelle: g, ort: sicherOrt + "2", uuid: "AAAAAAAA-0000-0000-0000-000000000001", anzahl: 2)) { XCTAssertTrue("\($0)".contains("decken"), "\($0)") }
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: sicherOrt + "2"))?.count ?? 0, 0)
    }

    // MARK: Nachpruefung

    func testNachpruefungSauberUndNegativfaelle() throws {
        let f = try abbild("p", journal: false, marker: false)
        let r = try nachpruefung(pfad: f, tief: false)
        XCTAssertTrue(r.ok, "\(r.probleme)")
        let tief = try nachpruefung(pfad: f, tief: true)
        XCTAssertTrue(tief.ok, "\(tief.probleme) \(tief.hinweise)")
        // 0x4000 im ALTERNATIVEN Header (primaer sauber)
        let size = UInt64(lies(f).count)
        var k = try kopieMitBits(f, nach: "alt4000") { _ in }
        try patch(k, size - 1024 + 4 + 2, [0x40])
        var x = try nachpruefung(pfad: k, tief: false); XCTAssertFalse(x.ok); XCTAssertTrue(x.probleme.contains { $0.contains("alternativen") && $0.contains("0x4000") }, "\(x.probleme)")
        // freeBlocks im primaeren Header verfaelscht
        k = try kopieMitBits(f, nach: "frei") { _ in }
        try patch(k, 1024 + 48, [0x00, 0x00, 0x00, 0x01])
        x = try nachpruefung(pfad: k, tief: false); XCTAssertFalse(x.ok); XCTAssertTrue(x.probleme.contains { $0.contains("freeBlocks") }, "\(x.probleme)")
        // Struktur-Abweichung im Ersatz-Header (blockSize)
        k = try kopieMitBits(f, nach: "struktur") { _ in }
        try patch(k, size - 1024 + 40 + 3, [0x77])
        x = try nachpruefung(pfad: k, tief: false); XCTAssertFalse(x.ok); XCTAssertTrue(x.probleme.contains { $0.contains("blockSize") }, "\(x.probleme)")
        // Zaehler im Ersatz-Header veraltet = nur Hinweis
        k = try kopieMitBits(f, nach: "zaehler") { _ in }
        try patch(k, size - 1024 + 32 + 3, [0x55])
        x = try nachpruefung(pfad: k, tief: false); XCTAssertTrue(x.ok, "\(x.probleme)"); XCTAssertTrue(x.hinweise.contains { $0.contains("fileCount") })
        // Journal-Bit ohne gueltigen Journalbereich bzw. 0x100 fehlt (Tor-Regeln)
        k = try kopieMitBits(f, nach: "unsauber") { _ in }
        try patch(k, 1024 + 4 + 2, [0x00]); // 0x100 liegt im Byte 2 (Bit 0x01 des 3. Bytes): 0x0100 -> Byte 2 = 0x01
        x = try nachpruefung(pfad: k, tief: false); XCTAssertFalse(x.ok, "fehlendes Unmounted-Bit muss auffallen")
    }

    // MARK: Merker / sicheres Abziehen

    func testMerkerUeberlebtNeustartUndVerschwindenImSchreiben() throws {
        let u = "AAAAAAAA-0000-0000-0000-000000000001"
        let a = Datenablage(ordner: "\(dir)/m")
        a.merkerAendern(u) { $0.rwAktiv = true; $0.bsd = "disk99"; $0.ort = "/x" }
        let a2 = Datenablage(ordner: "\(dir)/m")   // "Neustart"
        XCTAssertTrue(a2.merker(u).rwAktiv)
        var ereignisse: [AbziehWaechter.Ereignis] = []
        let w = AbziehWaechter(uuid: u, ablage: a2) { ereignisse.append($0) }
        w.verschwunden(bsd: "disk98")                       // anderes Geraet: nichts
        XCTAssertNil(a2.merker(u).offenePruefung); XCTAssertTrue(ereignisse.isEmpty)
        w.verschwunden(bsd: "disk99")
        XCTAssertNotNil(a2.merker(u).offenePruefung); XCTAssertFalse(a2.merker(u).rwAktiv)
        XCTAssertTrue(a2.protokollLesen().contains { $0.text.contains("Schreibzustand getrennt") })
        // nur lesend verschwunden: keine Warnung
        a2.merkerAendern(u) { $0 = Merker(); $0.bsd = "disk99" }
        w.verschwunden(bsd: "disk99"); XCTAssertNil(a2.merker(u).offenePruefung)
    }

    func testAbziehWaechterDiskArbitrationCallback() throws {
        let dev = try anhaengen(try abbild("w", journal: false, marker: false)); let u = try uuid(dev)
        let a = Datenablage(ordner: "\(dir)/w")
        let bsd = String(dev.dropFirst(5))
        a.merkerAendern(u) { $0.rwAktiv = true; $0.bsd = bsd }
        let ex = expectation(description: "getrennt")
        let w = AbziehWaechter(uuid: u, ablage: a) { if case .getrennt(let b, let sw) = $0, b == bsd { XCTAssertTrue(sw); ex.fulfill() } }
        w.start()
        XCTAssertEqual(ausfuehren("/usr/bin/hdiutil", ["detach", dev]).0, 0); geraete.removeAll { $0 == dev }
        wait(for: [ex], timeout: 15); w.stop()
        XCTAssertNotNil(a.merker(u).offenePruefung)
    }

    func testEinhaengenGateBeiOffenerPruefungOhneMount() throws {
        try XCTSkipUnless(modulStatus().freigeschaltet, "Modul nicht freigeschaltet")
        let abb = try abbild("g", journal: false)
        let bad = try kopieMitBits(abb, nach: "gfrei") { _ in }
        try patch(bad, 1024 + 48, [0x00, 0x00, 0x00, 0x01])    // freeBlocks falsch -> Nachpruefung rot
        let dev = try anhaengen(bad); let u = try uuid(dev)
        let k = kern(u, try freigabe([eintrag(u, "schreiben")]))
        k.ablage.merkerAendern(u) { $0.offenePruefung = "Test: im Schreiben getrennt" }
        XCTAssertThrowsError(try k.einhaengen(modus: .schreiben, ort: ort())) { XCTAssertEqual(($0 as? AppFehler)?.code, 33, "\($0)") }
        XCTAssertNil(einhaengungen()["/dev/" + String(dev.dropFirst(5))], "Gate darf nicht einhaengen")
        XCTAssertEqual(eigeneSicherungen(ort: sicherOrt, uuid: u).count, 0, "Gate vor Sicherung")
        XCTAssertNotNil(k.ablage.merker(u).offenePruefung, "Merker darf bei Rot nicht fallen")
    }

    func testRwOhneSicherungMoeglichNie() throws {
        try XCTSkipUnless(modulStatus().freigeschaltet, "Modul nicht freigeschaltet")
        let dev = try anhaengen(try abbild("r")); let u = try uuid(dev)
        let k = kern(u, try freigabe([eintrag(u, "schreiben")]))
        var e = k.ablage.einstellungen(); e.sicherungOrt = NSTemporaryDirectory() + "drobo_nein"; k.ablage.einstellungenSetzen(e)   // Systemplatte
        XCTAssertThrowsError(try k.einhaengen(modus: .schreiben, ort: ort())) { XCTAssertEqual(($0 as? AppFehler)?.code, 30, "\($0)") }
        XCTAssertNil(einhaengungen()["/dev/" + String(dev.dropFirst(5))], "kein rw-Mount ohne Sicherung")
        XCTAssertFalse(k.ablage.merker(u).rwAktiv)
    }

    func testTimeMachineRolleWirdNieEingehaengt() throws {
        let dev = try anhaengen(try abbild("t", journal: false)); let u = try uuid(dev)
        let k = kern(u, try freigabe([eintrag(u, "nurlesen")]))
        var e = k.ablage.einstellungen(); e.drobos.append(DroboEintrag(uuid: u, name: "Drobo 8", rolle: .timemachine)); k.ablage.einstellungenSetzen(e)
        XCTAssertThrowsError(try k.einhaengen(ort: ort())) { XCTAssertEqual(($0 as? AppFehler)?.code, 34) }
        XCTAssertNil(einhaengungen()["/dev/" + String(dev.dropFirst(5))])
        XCTAssertEqual(Einstellungen().drobos.first?.uuid, vorgabeUUID); XCTAssertFalse(Einstellungen().spotlightAusgeschlossen)
    }

    // MARK: Wegsichern

    func testWegsichernInkrementellMitPruefsumme() throws {
        let fm = FileManager.default
        let q = "\(dir)/quelle/daten", z = "\(dir)/ziel"
        try fm.createDirectory(atPath: q + "/sub", withIntermediateDirectories: true)
        try Data("eins".utf8).write(to: URL(fileURLWithPath: q + "/a.txt")); try Data(repeating: 7, count: 300_000).write(to: URL(fileURLWithPath: q + "/sub/b.bin"))
        try fm.createSymbolicLink(atPath: q + "/l", withDestinationPath: "a.txt")
        var b = try ordnerWegsichern(quelle: q, ziel: z)
        XCTAssertEqual(b.kopiert, 3); XCTAssertEqual(b.geprueft, 2); XCTAssertTrue(b.ok, b.text)
        XCTAssertEqual(lies(z + "/daten/sub/b.bin"), lies(q + "/sub/b.bin"))
        b = try ordnerWegsichern(quelle: q, ziel: z)
        XCTAssertEqual(b.kopiert, 0, "zweiter Lauf muss alles ueberspringen"); XCTAssertEqual(b.uebersprungen, 3)
        // geaenderte Datei (andere Groesse) wird neu kopiert, Rest bleibt
        try Data("zwei!".utf8).write(to: URL(fileURLWithPath: q + "/a.txt"))
        b = try ordnerWegsichern(quelle: q, ziel: z)
        XCTAssertEqual(b.kopiert, 1); XCTAssertEqual(lies(z + "/daten/a.txt"), Data("zwei!".utf8))
        // gleiche Groesse, andere mtime -> neu; Quelle unveraendert
        let vorher = lies(q + "/sub/b.bin")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5000)], ofItemAtPath: q + "/sub/b.bin")
        b = try ordnerWegsichern(quelle: q, ziel: z); XCTAssertEqual(b.kopiert, 1); XCTAssertEqual(lies(q + "/sub/b.bin"), vorher)
        XCTAssertFalse(fm.fileExists(atPath: z + "/daten/sub/b.bin.drobo-teil"))
    }

    func testWegsichernZielAblehnungen() throws {
        let q = "\(dir)/q2"; try FileManager.default.createDirectory(atPath: q, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ordnerWegsichern(quelle: q, ziel: q + "/in"), "Ziel in Quelle") { XCTAssertEqual(($0 as? AppFehler)?.code, 35) }
        XCTAssertThrowsError(try ordnerWegsichern(quelle: q, ziel: "\(dir)/mnt/ziel", verboten: ["\(dir)/mnt"]), "Ziel auf der Drobo") { XCTAssertEqual(($0 as? AppFehler)?.code, 35) }
        XCTAssertThrowsError(try ordnerWegsichern(quelle: "\(dir)/gibtsnicht", ziel: "\(dir)/z")) { XCTAssertEqual(($0 as? AppFehler)?.code, 35) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/z"))
    }

    func testWegsichernPruefsummenFehlerWirdGemeldet() throws {
        // Orakel-Test der Schutzregel: sha256Datei unterscheidet Inhalte (Kopie mit anderem Inhalt darf nicht als gleich gelten)
        let a = "\(dir)/a", b = "\(dir)/b"
        try Data("x".utf8).write(to: URL(fileURLWithPath: a)); try Data("y".utf8).write(to: URL(fileURLWithPath: b))
        XCTAssertNotEqual(try sha256Datei(a), try sha256Datei(b))
    }

    // MARK: Tempo

    func testTempoLesenUndSchreibenVoraussetzungen() throws {
        let q = "\(dir)/tempo"; try FileManager.default.createDirectory(atPath: q, withIntermediateDirectories: true)
        XCTAssertThrowsError(try tempoLesen(ort: q, uuid: "U")) { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }   // keine grosse Datei
        try Data(repeating: 1, count: 20 << 20).write(to: URL(fileURLWithPath: q + "/gross.bin"))
        let a = Datenablage(ordner: "\(dir)/tempoA")
        let m = try tempoLesen(ort: q, uuid: "U", ablage: a)
        XCTAssertEqual(m.dateien, 1); XCTAssertEqual(m.bytes, 20 << 20); XCTAssertGreaterThan(m.mbProSekunde, 1); XCTAssertEqual(a.tempoVerlauf().count, 1)
        let w = try tempoSchreiben(ort: q, uuid: "U", mib: 4, ablage: a)
        XCTAssertEqual(w.art, "schreiben"); XCTAssertFalse(FileManager.default.fileExists(atPath: q + "/.drobo-tempotest"), "Testordner aufgeraeumt")
        XCTAssertEqual(a.tempoVerlauf().count, 2)
    }
}

extension KernTests {
    /// /Volumes: Ordner kommt vom Dienst (hier Attrappe), Fehler beim Mount raeumt ihn wieder weg; Aushaengen entfernt ihn.
    func testEinhaengenVolumesOrtUeberDienstUndAufraeumen() throws {
        let dev = try anhaengen(try abbild("v", journal: false, marker: false)); let u = try uuid(dev)
        var k = kern(u, try freigabe([eintrag(u, "nurlesen")]), modul: ModulStatus(installiert: true, freigeschaltet: true))
        var angelegt: [String] = [], entfernt: [String] = []
        k.ordnerAnlegen = { angelegt.append($0); return "\(self.dir)/vol" }
        k.ordnerEntfernen = { entfernt.append($0); return nil }
        // Mount scheitert (Abbild ohne Marker/Freigabe im Modul) -> Ordner wird wieder entfernt, auch ohne dass etwas eingehaengt ist
        XCTAssertThrowsError(try k.einhaengen(ort: vorgabeVolumes))
        XCTAssertEqual(angelegt, [u]); XCTAssertEqual(entfernt, [u])
        XCTAssertNil(einhaengungen()["/dev/" + dev.dropFirst(5)])
    }
}
