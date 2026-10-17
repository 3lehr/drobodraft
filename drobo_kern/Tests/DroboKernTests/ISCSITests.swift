import XCTest
@testable import DroboKern

/// iSCSI-Client gegen das Python-Pruefziel (Tests/iscsi_ziel.py) ueber Abbilddateien unter $DROBO_TESTDIR. Nie ein echtes Geraet.
/// Das Ziel protokolliert jeden Befehl, den es wirklich erreichte; "ohne zu senden" wird an diesem Log belegt, nicht am Rueckgabewert.
final class ISCSITests: XCTestCase {
    var dir = ""
    var prozess: Process?

    override func setUpWithError() throws {
        guard let base = Kern.umgebung("DROBO_TESTDIR") else { throw XCTSkip("DROBO_TESTDIR nicht gesetzt") }
        dir = "\(base)/iscsi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        prozess?.terminate(); prozess?.waitUntilExit()    // nur der eigene Prozess, nie per Name
        try? FileManager.default.removeItem(atPath: dir)
    }

    var logPfad: String { dir + "/ziel.jsonl" }

    /// Startet das Ziel (2 LUNs a 4 MiB) und gibt den Port zurueck.
    func ziel(_ extra: [String] = [], mib: Int = 4) throws -> UInt16 {
        for i in 0..<2 { FileManager.default.createFile(atPath: "\(dir)/lun\(i).img", contents: nil); truncate("\(dir)/lun\(i).img", off_t(mib) << 20) }
        let skript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("iscsi_ziel.py").path
        let p = Process(); let aus = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", skript, "--image", "\(dir)/lun0.img", "--image", "\(dir)/lun1.img", "--log", logPfad] + extra
        p.standardOutput = aus; try p.run(); prozess = p
        var zeile = Data()
        while !zeile.contains(10) { let d = aus.fileHandleForReading.availableData; if d.isEmpty { XCTFail("Ziel startete nicht"); break }; zeile += d }
        let teile = String(decoding: zeile, as: UTF8.self).split(separator: " ")
        return UInt16(teile.last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "") ?? 0
    }

    func log() -> [[String: Any]] {
        let t = (try? String(contentsOfFile: logPfad, encoding: .utf8)) ?? ""
        return t.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    func ereignisse(_ n: String) -> [[String: Any]] { log().filter { $0["ereignis"] as? String == n } }

    func sitzung(_ port: UInt16, zeit: TimeInterval = 5) throws -> ISCSISitzung {
        let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: zeit)
        let z = try d.ziele(); XCTAssertNotNil(z.first?.name); d.abmelden()
        return try ISCSISitzung(host: "127.0.0.1", port: port, ziel: z[0].name, zeitgrenze: zeit)
    }
    func muster(_ n: Int, _ seed: UInt8 = 7) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ $0 >> 8) } }

    // MARK: Lesen

    func testDiscoveryLoginUndLesebefehle() throws {
        let s = try sitzung(try ziel())
        try s.testUnitReady(lun: 0)
        XCTAssertEqual(String(decoding: try s.inquiry(lun: 0)[8..<28], as: UTF8.self), "DROBO   DroboPro    ")
        XCTAssertEqual(try s.lunListe(), [0, 1])
        let k = try s.kapazitaet(lun: 1)
        XCTAssertEqual(k.bloecke, 8192); XCTAssertEqual(k.blockgroesse, 512)
        XCTAssertEqual(try s.lesen(lun: 0, lba: 0, bloecke: 8), [UInt8](repeating: 0, count: 4096))
        XCTAssertEqual(s.login["MaxBurstLength"], "524288")
        s.abmelden()
    }

    func testModeSenseSeiteMitGemessenenBytes() throws {
        let s = try sitzung(try ziel())
        XCTAssertEqual(try s.modeSense3A(lun: 0, unterseite: 0x01).map { String(format: "%02x", $0) }.joined(), "7a01001808021001000007ffffffff00000000000000000100000000")
        XCTAssertEqual(try s.modeSense3A(lun: 0, unterseite: 0x06).map { String(format: "%02x", $0) }.joined(), "7a060002000b")
    }

    // MARK: Schreiben, Grenzwerte, Stueckelung

    func testSchreibenByteGenauMitAbbildPruefung() throws {
        let s = try sitzung(try ziel())
        let d = muster(512 * 40)
        try s.schreiben(lun: 1, lba: 10, daten: d)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 10, bloecke: 40), d)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 9, bloecke: 1), [UInt8](repeating: 0, count: 512), "Nachbarblock unberuehrt")
        let abbild = try Data(contentsOf: URL(fileURLWithPath: dir + "/lun1.img"))
        XCTAssertEqual([UInt8](abbild[5120..<5120 + d.count]), d)
        XCTAssertEqual(try s.lesen(lun: 0, lba: 10, bloecke: 1), [UInt8](repeating: 0, count: 512), "LUN 0 unberuehrt")
    }

    /// 524288 = eine Kommando-Obergrenze; +512 -> zwei Befehle (524288 + 512); -512 -> einer. 524287/524289 sind keine Blockvielfachen.
    func testGrenzwerteSchreibmenge() throws {
        let s = try sitzung(try ziel())
        func schreibbefehle() -> [Int] { ereignisse("write").map { $0["bytes"] as! Int } }
        try s.schreiben(lun: 1, lba: 0, daten: muster(524288 - 512)); XCTAssertEqual(schreibbefehle(), [523776])
        try s.schreiben(lun: 1, lba: 0, daten: muster(524288)); XCTAssertEqual(schreibbefehle(), [523776, 524288])
        let gross = muster(524288 + 512, 3)
        try s.schreiben(lun: 1, lba: 100, daten: gross)
        XCTAssertEqual(schreibbefehle(), [523776, 524288, 524288, 512])
        XCTAssertLessThanOrEqual(schreibbefehle().max()!, 524288)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 100, bloecke: 1025), gross)
        let vorher = ereignisse("befehl").count
        for n in [524287, 524289] { XCTAssertThrowsError(try s.schreiben(lun: 1, lba: 0, daten: muster(n)), "n=\(n)") { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } } }
        // Gate unmittelbar: 524289 B in EINEM WRITE(16) wird abgelehnt, 524288 B nicht
        var cdb = [UInt8](repeating: 0, count: 16); cdb[0] = 0x8A; cdb[13] = 1
        XCTAssertNil(ISCSISitzung.verbot(cdb: cdb, schreiben: 524288, lesen: 0))
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb, schreiben: 524289, lesen: 0))
        XCTAssertEqual(ereignisse("befehl").count, vorher, "abgelehnte Aufrufe erreichten das Ziel nicht")
    }

    func testR2TInKleinenStueckenUndSegmentgrenze() throws {
        let s = try sitzung(try ziel(["--r2t-chunk", "4096", "--max-seg", "2048"]))
        let d = muster(524288, 9)
        try s.schreiben(lun: 1, lba: 0, daten: d)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 0, bloecke: 1024), d)
        let aus = ereignisse("dataout")
        XCTAssertEqual(aus.count, (524288 - 2048) / 2048, "2048 B gehen sofort im Command-PDU, der Rest per R2T")
        XCTAssertLessThanOrEqual(aus.map { $0["laenge"] as! Int }.max()!, 2048)
        XCTAssertTrue(ereignisse("verletzung").isEmpty)
    }

    /// DroboPro: 256 KiB Immediate (MRDSL des Ziels) + R2T fuer den Rest; ohne Immediate-Daten stuerzt sie ab (Ziel bildet das nach).
    func testImmediateTeilPlusR2TRest() throws {
        let s = try sitzung(try ziel(["--max-seg", "262144"]))
        XCTAssertEqual(s.login["ImmediateData"], "Yes")
        let d = muster(524288, 5)
        try s.schreiben(lun: 1, lba: 16, daten: d)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 16, bloecke: 1024), d)
        let w = ereignisse("write").first!
        XCTAssertEqual(w["sofort"] as? Int, 262144)
        XCTAssertEqual(ereignisse("dataout").map { $0["laenge"] as! Int }.reduce(0, +), 262144, "Rest 262144 per R2T")
        let klein = muster(4096, 1)
        try s.schreiben(lun: 1, lba: 5000, daten: klein)
        XCTAssertEqual(ereignisse("write").last?["sofort"] as? Int, 4096, "4 KiB komplett immediate")
        XCTAssertTrue(ereignisse("ABSTURZ write-ohne-immediate").isEmpty)
    }

    func testWriteOhneImmediateWirdNieGesendet() throws {
        let s = try sitzung(try ziel(["--refuse-immediate"]))
        XCTAssertEqual(s.login["ImmediateData"], "No")
        XCTAssertThrowsError(try s.schreiben(lun: 1, lba: 0, daten: muster(4096))) { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } }
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(ereignisse("write").isEmpty, "kein WRITE erreichte das Ziel")
        XCTAssertTrue(ereignisse("ABSTURZ write-ohne-immediate").isEmpty)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 0, bloecke: 1).count, 512, "Lesen geht weiter")
    }

    // MARK: Allowlist

    func testAllowlistLehntVerboteneBefehleOhneSendenAb() throws {
        let s = try sitzung(try ziel())
        try s.testUnitReady(lun: 0)
        let vorher = log().count
        func cdb(_ op: UInt8, _ n: Int = 16, _ set: [Int: UInt8] = [:]) -> [UInt8] { var c = [UInt8](repeating: 0, count: n); c[0] = op; for (i, v) in set { c[i] = v }; return c }
        let verboten: [[UInt8]] = [
            cdb(0xEA, 10), cdb(0x15, 6), cdb(0x55, 10), cdb(0xE1, 10), cdb(0xE2, 10),      // Drobo-Verwaltung, MODE SELECT
            cdb(0x2A, 10), cdb(0x04, 6), cdb(0x42, 10), cdb(0x93, 16), cdb(0x8E, 16),       // WRITE(10), FORMAT, UNMAP, WRITE SAME, WRITE AND VERIFY
            cdb(0x9E, 16, [1: 0x11]),                                                       // SERVICE ACTION IN anderer Art
            cdb(0x5A, 10, [1: 8, 2: 0x3A, 3: 0x07, 7: 2]),                                  // Unterseite nicht auf der Liste
            cdb(0x5A, 10, [1: 8, 2: 0x3B, 3: 0x01, 7: 2]),                                  // andere Seite
            cdb(0x5A, 10, [1: 8, 2: 0x3A, 3: 0x01, 7: 0x10]),                               // Allokationslaenge 4096 haengt die DroboPro
            cdb(0x5A, 10, [1: 8, 2: 0x3A, 3: 0x01, 7: 2, 8: 1]),                            // 513
            cdb(0x88, 12),                                                                  // falsche CDB-Laenge
        ]
        for c in verboten {
            XCTAssertThrowsError(try s.befehl(lun: 0, cdb: c, lesen: 512), "op \(String(c[0], radix: 16))") { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } }
        }
        // Datenrichtung: Daten bei Nicht-WRITE verboten
        XCTAssertThrowsError(try s.befehl(lun: 0, cdb: cdb(0x12, 6), daten: [1])) { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } }
        XCTAssertEqual(log().count, vorher, "kein verbotener Befehl hat das Ziel erreicht")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x5A, 10, [1: 8, 2: 0x3A, 3: 0x01, 7: 0x10]), schreiben: 0, lesen: 4096))
        try s.testUnitReady(lun: 0)     // Sitzung lebt weiter: Gate-Ablehnung ist kein Sitzungsfehler
    }

    // MARK: Zeit und Abbruch

    func testZeitueberschreitungWirftStattZuHaengen() throws {
        let port = try ziel(["--swallow", "2"])      // Befehl 1 = TUR geht durch, Befehl 2 wird verschluckt
        let s = try sitzung(port, zeit: 1)
        try s.testUnitReady(lun: 0)
        let t0 = Date()
        XCTAssertThrowsError(try s.inquiry(lun: 0)) { guard case ISCSIFehler.zeitueberschreitung = $0 else { return XCTFail("\($0)") } }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4)
        XCTAssertThrowsError(try s.testUnitReady(lun: 0), "Sitzung nach Zeitueberschreitung tot")
    }

    func testVerbindungsabbruchWirft() throws {
        let s = try sitzung(try ziel(["--drop-after", "2"]))
        try s.testUnitReady(lun: 0); try s.testUnitReady(lun: 0)
        XCTAssertThrowsError(try s.testUnitReady(lun: 0)) { guard case ISCSIFehler.verbindung = $0 else { return XCTFail("\($0)") } }
        XCTAssertThrowsError(try s.testUnitReady(lun: 0))
    }

    func testAbbruchMittenImSchreibenWirft() throws {
        let s = try sitzung(try ziel(["--drop-after", "1"]))      // Befehl 1 = READ CAPACITY, Befehl 2 = WRITE -> Verbindung zu
        XCTAssertThrowsError(try s.schreiben(lun: 1, lba: 0, daten: muster(4096))) { guard case ISCSIFehler.verbindung = $0 else { return XCTFail("\($0)") } }
        XCTAssertEqual(ereignisse("dataout").count, 0)
    }

    // MARK: Neueinrichtung (iscsi-format)

    func formatiere(_ port: UInt16, lun: Int = 1, ausfuehren: Bool, groesse: UInt64? = nil, eingehaengt: @escaping (Int) -> Bool = { _ in false }, _ log: inout [String]) throws {
        var m: [String] = []
        defer { log = m }
        try iscsiFormat(host: "127.0.0.1", port: port, lun: lun, name: "FMTTEST", partitionBytes: groesse, ausfuehren: ausfuehren, arbeitsordner: dir, eingehaengt: eingehaengt, meldung: { m.append($0) })
    }

    func testFormatTrockenlaufSchreibtNichts() throws {
        let port = try ziel(mib: 128)
        var l: [String] = []
        try formatiere(port, ausfuehren: false, &l)
        XCTAssertTrue(l.contains { $0.hasPrefix("dry run") }, "\(l)")
        XCTAssertTrue(ereignisse("write").isEmpty, "Trockenlauf darf nichts schreiben")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/lun1.img")).filter { $0 != 0 }.count, 0)
    }

    /// Betreiber 2026-10-17: jede LUN der DroboPro darf formatiert werden (vorher nur LUN 1).
    func testFormatTrockenlaufAuchFuerLUN0() throws {
        let port = try ziel(mib: 128)
        var l: [String] = []
        try formatiere(port, lun: 0, ausfuehren: false, &l)
        XCTAssertTrue(l.contains { $0.hasPrefix("plan: LUN 0") }, "\(l)")
        XCTAssertTrue(ereignisse("write").isEmpty)
    }

    /// Eingehaengte LUN: verweigert, bevor das Ziel kontaktiert wird.
    func testFormatLehntEingehaengteLUNAb() throws {
        let port = try ziel(mib: 128)
        var l: [String] = []
        XCTAssertThrowsError(try formatiere(port, lun: 1, ausfuehren: true, eingehaengt: { $0 == 1 }, &l)) { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } }
        XCTAssertTrue(log().isEmpty, "LUN eingehaengt: Ziel nicht kontaktiert")
        XCTAssertThrowsError(try formatiere(port, lun: -1, ausfuehren: false, &l))
    }

    /// Ergebnis wird vom macOS-Kernel gerichtet: GPT muss sich anhaengen lassen, die Partition muss fsck_hfs -fn bestehen.
    func testFormatErgebnisBestehtFsckUndNurLUN1Beschrieben() throws {
        let port = try ziel(mib: 128)
        try Data(repeating: 0xA5, count: 128 << 20).write(to: URL(fileURLWithPath: dir + "/lun1.img"))      // Altlast: nicht geschriebene belegte Bloecke fielen in fsck auf
        var l: [String] = []
        try formatiere(port, ausfuehren: true, &l)
        XCTAssertTrue(l.contains { $0.hasPrefix("verified:") }, "\(l)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/lun0.img")).filter { $0 != 0 }.count, 0, "LUN 0 unberuehrt")
        XCTAssertLessThanOrEqual(ereignisse("write").map { $0["bytes"] as! Int }.max()!, 524288)
        XCTAssertTrue(ereignisse("befehl").allSatisfy { ($0["lun"] as! Int) == 1 || ($0["op"] as! Int) == 0xA0 }, "nur LUN 1 (und REPORT LUNS) erreichte das Ziel")
        let (rc, out) = ausfuehren("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", dir + "/lun1.img"])
        XCTAssertEqual(rc, 0, out)
        let dev = out.split(separator: "\n").first?.split(separator: " ").first.map(String.init) ?? ""
        defer { ausfuehren("/usr/bin/hdiutil", ["detach", dev, "-force"]) }
        XCTAssertTrue(out.contains("Apple_HFS") || out.contains("48465300"), out)
        let teil = out.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }.first { $0.hasPrefix(dev + "s") } ?? ""
        let (r2, o2) = ausfuehren("/sbin/fsck_hfs", ["-fn", "/dev/r" + teil.dropFirst(5)])
        XCTAssertEqual(r2, 0, o2); XCTAssertTrue(o2.contains("appears to be OK"), o2)
        let (_, pl) = ausfuehren("/usr/sbin/diskutil", ["info", "-plist", teil])
        let uuidDiskutil = ((try? PropertyListSerialization.propertyList(from: Data(pl.utf8), format: nil)) as? [String: Any])?["VolumeUUID"] as? String
        let vh = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir + "/lun1.img"))[(2048 * 512 + 1024)..<(2048 * 512 + 1536)])
        XCTAssertNotNil(uuidDiskutil); XCTAssertEqual(hfsVolumeUUID(vh: vh), uuidDiskutil, "Volume-UUID wie diskutil")
        let (_, nf) = ausfuehren("/usr/sbin/diskutil", ["info", teil]); XCTAssertTrue(nf.contains("Journal:                  Not Journaled") || !nf.contains("Journal:                  Journaled"), nf)
    }

    // MARK: Netzwerk-Drobo (Status, Entdecken, Sicherung)

    func testNetzStatusAusDenSeiten() throws {
        let s = try sitzung(try ziel())
        let (st, info) = try netzStatus(sitzung: s)
        XCTAssertEqual(st.modell, "DroboPro"); XCTAssertEqual(st.schaechte.count, 8); XCTAssertEqual(st.schaechte.filter { $0.belegt }.count, 7)
        XCTAssertEqual(info, NetzInfo(name: "DroboPro", gelbProzent: 85, rotProzent: 95))
        XCTAssertNotNil(st.kapazitaet); XCTAssertEqual(st.protokoll, "0.11")
        XCTAssertTrue(ereignisse("verschluckt").isEmpty, "alle Seiten mit passender Laenge angefragt")
    }

    func testNetzEntdeckenUndSicherungByteGleich() throws {
        let port = try ziel(mib: 128)
        var l: [String] = []
        try formatiere(port, ausfuehren: true, &l)
        let s = try sitzung(port)
        let luns = try netzLuns(sitzung: s)
        XCTAssertEqual(luns.map { $0.lun }, [1], "LUN 0 hat keine GPT/HFS+-Partition")
        let img = try Data(contentsOf: URL(fileURLWithPath: dir + "/lun1.img"))
        let p0 = 2048 * 512
        XCTAssertEqual(luns[0].uuid, hfsVolumeUUID(vh: [UInt8](img[(p0 + 1024)..<(p0 + 1536)])))
        let ort = dir + "/sicherung"
        let teil = try GPT.ersteHFS { try s.lesen(lun: 1, lba: $0, bloecke: $1) }!
        let r = try netzSicherung(sitzung: s, lun: 1, partition: teil, uuid: luns[0].uuid, ort: ort, anzahl: 2)
        XCTAssertEqual(sicherungPruefen(ordner: r.ordner), [])
        let kopf = try Data(contentsOf: URL(fileURLWithPath: r.ordner + "/kopf_1MiB.bin")), ende = try Data(contentsOf: URL(fileURLWithPath: r.ordner + "/ende_1MiB.bin"))
        XCTAssertEqual(kopf, img[p0..<(p0 + 1 << 20)], "Kopf der Partition byte-gleich")
        XCTAssertEqual(ende, img[(p0 + Int(teil.bloecke) * 512 - (1 << 20))..<(p0 + Int(teil.bloecke) * 512)], "Ende der Partition byte-gleich")
        XCTAssertEqual(eigeneSicherungen(ort: ort, uuid: luns[0].uuid).count, 1)
        XCTAssertThrowsError(try netzSicherung(sitzung: s, lun: 1, partition: teil, uuid: luns[0].uuid, ort: "/private/tmp/gleich-systemplatte", anzahl: 2), "Systemplatte als Sicherungsort abgelehnt")
    }

    // MARK: LAN-Suche

    func testSuchKandidatenGrenzen() {
        func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
        let k24 = LanSuche.kandidaten(adresse: ip(192, 168, 178, 53), maske: 0xFFFF_FF00)
        XCTAssertEqual(k24.count, 253); XCTAssertFalse(k24.contains("192.168.178.53")); XCTAssertFalse(k24.contains("192.168.178.0")); XCTAssertFalse(k24.contains("192.168.178.255"))
        XCTAssertEqual(k24.first, "192.168.178.1"); XCTAssertEqual(k24.last, "192.168.178.254")
        XCTAssertEqual(LanSuche.kandidaten(adresse: ip(10, 1, 2, 3), maske: 0xFFFF_0000).count, 1021, "groesseres Netz: /22 um die eigene Adresse, nie mehr als 1024")
        XCTAssertEqual(LanSuche.kandidaten(adresse: ip(192, 168, 1, 1), maske: 0xFFFF_FFFC), ["192.168.1.2"], "/30")
        XCTAssertEqual(LanSuche.kandidaten(adresse: ip(192, 168, 1, 1), maske: 0xFFFF_FFFE), [], "/31 hat keine Hosts")
        XCTAssertLessThanOrEqual(LanSuche.kandidaten(adresse: ip(10, 0, 0, 5), maske: 0).count, 1024)
    }

    func testLanSucheFindetNurDroboZieleUndNurPrivate() throws {
        let drobo = try ziel(["--iqn", "iqn.2005-06.com.datarobotics:drobopro.test.node0"])
        let suche = LanSuche(testPort: drobo)
        XCTAssertEqual(suche.suchen(kandidaten: ["127.0.0.1"]), ["127.0.0.1"])
        XCTAssertEqual(suche.suchen(kandidaten: ["127.0.0.1"], ausnehmen: ["127.0.0.1"]), [], "ausgenommene Adresse wird nicht angesprochen")
        XCTAssertTrue(ereignisse("befehl").isEmpty)
        var oeffentlich = LanSuche(); oeffentlich.port = drobo; oeffentlich.verbindungsfrist = 0.1
        XCTAssertEqual(oeffentlich.suchen(kandidaten: ["127.0.0.1", "8.8.8.8", "1.1.1.1"]), [], "Dienst-Init: Loopback und oeffentliche Adressen nie")
        XCTAssertEqual(suche.suchen(kandidaten: ["127.0.0.2", "8.8.8.8", "example.com"]), [], "nur die erlaubte Adresse wird versucht")
    }

    func testFremdesIQNIstKeineDrobo() throws {
        let fremd = try ziel(["--iqn", "iqn.2010-01.com.example:nas"])
        XCTAssertEqual(LanSuche(testPort: fremd).suchen(kandidaten: ["127.0.0.1"]), [], "Praefix-Filter")
    }

    func testDrobosSuchenListetFundeOhneUebernahme() throws {
        let port = try ziel(["--iqn", "iqn.2005-06.com.datarobotics:drobopro.test.node0"], mib: 128)
        var l: [String] = []; try formatiere(port, ausfuehren: true, &l)
        let such = LanSuche(testPort: port)
        let r = drobosSuchen(usbVendor: "KeinHerstellerDerExistiert", lanHosts: { such.suchen(kandidaten: ["127.0.0.1"], ausnehmen: $0) },
                             lunsFuer: { _ in let s = try self.sitzung(port); defer { s.abmelden() }; return try netzLuns(sitzung: s) })
        XCTAssertEqual(r.usb, []); XCTAssertNil(r.lanFehler)
        XCTAssertEqual(r.lan.map { $0.host }, ["127.0.0.1"]); XCTAssertEqual(r.lan.first?.luns.map { $0.lun }, [1])
        let r2 = drobosSuchen(lan: false, usbVendor: "KeinHerstellerDerExistiert", lanHosts: { _ in XCTFail("LAN nicht verlangt"); return [] })
        XCTAssertEqual(r2.lan, [])
        let r3 = drobosSuchen(usbVendor: "KeinHerstellerDerExistiert", lanHosts: { _ in throw ISCSIFehler.verbindung("x") }, lunsFuer: { _ in [] })
        XCTAssertNotNil(r3.lanFehler)
    }
}

/// Schutz der DroboPro-Sitzungen: feste ISID, Logout auch nach Fehler, Bremse bei Haenger. Ziel protokolliert Logins, Logouts und Befehle (Python-Pruefziel).
extension ISCSITests {
    func testISIDFestJeZweckUndVerschiedenZwischenZwecken() throws {
        XCTAssertEqual(ISCSISitzung.isid(maschine: "M", zweck: "status"), ISCSISitzung.isid(maschine: "M", zweck: "status"))
        XCTAssertNotEqual(ISCSISitzung.isid(maschine: "M", zweck: "status"), ISCSISitzung.isid(maschine: "M", zweck: "mount-lun0"))
        XCTAssertNotEqual(ISCSISitzung.isid(maschine: "M", zweck: "status"), ISCSISitzung.isid(maschine: "N", zweck: "status"))
        XCTAssertEqual(ISCSISitzung.isid(maschine: "M", zweck: "x").count, 6); XCTAssertEqual(ISCSISitzung.isid(maschine: "M", zweck: "x")[0], 0x80)
        let port = try ziel()
        for z in ["status", "status", "mount-lun1", "format"] {
            let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: 5); let n = try XCTUnwrap(d.ziele().first?.name); d.abmelden()
            let s = try ISCSISitzung(host: "127.0.0.1", port: port, ziel: n, zeitgrenze: 5, zweck: z); s.abmelden()
        }
        let normal = ereignisse("login").filter { $0["sitzung"] as? String == "Normal" }.compactMap { $0["isid"] as? String }
        XCTAssertEqual(normal.count, 4)
        XCTAssertEqual(normal[0], normal[1], "gleicher Zweck, gleiche ISID im Ziel-Log"); XCTAssertEqual(Set(normal).count, 3, "verschiedene Zwecke, verschiedene ISID")
        XCTAssertEqual(Set(ereignisse("login").compactMap { $0["initiator"] as? String }), [ISCSISitzung.initiatorName(maschine: ISCSISitzung.maschine)], "Initiator-Name ueberall gleich")
        let a = ISCSISitzung.initiatorName(maschine: "UUID-A")
        XCTAssertEqual(a, ISCSISitzung.initiatorName(maschine: "UUID-A"), "deterministisch")
        XCTAssertNotEqual(a, ISCSISitzung.initiatorName(maschine: "UUID-B"), "anderer Mac, anderer Name")
        XCTAssertNotNil(a.range(of: #"^iqn\.2026-10\.local\.drobodraft:[0-9a-f]{16}$"#, options: .regularExpression)); XCTAssertFalse(a.contains("UUID-A"))
    }

    func testLogoutNachZeitueberschreitung() throws {
        let port = try ziel(["--swallow", "1"])
        let s = try sitzung(port, zeit: 1)
        XCTAssertThrowsError(try s.inquiry(lun: 0)) { if case ISCSIFehler.zeitueberschreitung = $0 {} else { XCTFail("\($0)") } }
        for _ in 0..<30 where ereignisse("logout").filter({ $0["sitzung"] as? String == "Normal" }).isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(ereignisse("logout").filter { $0["sitzung"] as? String == "Normal" }.count, 1, "Ziel sieht den Logout, obwohl der Befehl in die Zeitueberschreitung lief")
    }

    func testBremseNachEinerZeitueberschreitungEinBefehlAmZiel() throws {
        let port = try ziel(["--hang-after", "0"])      // ab dem ersten Befehl haengt das Ziel
        let b = StatusBremse(); var abfragen = 0
        for i in 0..<6 {
            guard b.darfAbfragen(eingehaengt: false, jetzt: Date(timeIntervalSinceNow: Double(i) * 301)) else { continue }
            abfragen += 1
            do { _ = try netzStatus(sitzung: try sitzung(port, zeit: 1)); b.ergebnis(nil) } catch { b.ergebnis(error) }
        }
        XCTAssertEqual(b.zustand, .reagiertNicht); XCTAssertEqual(abfragen, 1)
        XCTAssertEqual(log().filter { $0["ereignis"] as? String == "befehl" }.count, 1, "genau ein Befehl am Ziel")
        b.erneutPruefen(); XCTAssertEqual(b.zustand, .bereit)
        XCTAssertTrue(b.darfAbfragen(eingehaengt: false)); XCTAssertFalse(b.darfAbfragen(eingehaengt: false), "hoechstens eine Status-Sitzung gleichzeitig")
    }

    func testBremseGrenzenAbstandEingehaengtUndGleichzeitig() {
        let b = StatusBremse(), t = Date()
        XCTAssertFalse(b.darfAbfragen(eingehaengt: true, jetzt: t), "eingehaengt: nie")
        XCTAssertTrue(b.darfAbfragen(eingehaengt: false, jetzt: t)); b.ergebnis(nil)
        XCTAssertFalse(b.darfAbfragen(eingehaengt: false, jetzt: t.addingTimeInterval(299)), "n-1")
        XCTAssertTrue(b.darfAbfragen(eingehaengt: false, jetzt: t.addingTimeInterval(300)), "n"); b.ergebnis(ISCSIFehler.verbindung("netz weg"))
        XCTAssertEqual(b.zustand, .bereit, "Netzfehler pausiert nicht, bremst nur ueber den Abstand")
    }

    func testFremderRechnerAbgelehntKeineWiederholung() throws {
        let port = try ziel(["--reject-other-initiator"])
        _ = try sitzung(port).abmelden()      // erster Initiator wird gemerkt
        let b = StatusBremse(); XCTAssertTrue(b.darfAbfragen(eingehaengt: false))
        do { _ = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: 5, initiator: "iqn.2026-10.local.fremd:rechner"); XCTFail("sollte abgelehnt werden"); b.ergebnis(nil) }
        catch { b.ergebnis(error); if case ISCSIFehler.belegt = error {} else { XCTFail("\(error)") } }
        XCTAssertEqual(b.zustand, .anderemRechner); XCTAssertFalse(b.darfAbfragen(eingehaengt: false, jetzt: Date(timeIntervalSinceNow: 9999)))
        XCTAssertEqual(ereignisse("abgelehnt").count, 1)
    }

    func testFalscheLaengeAmZielHaengtNurOhneGate() throws {
        let port = try ziel()
        let s = try sitzung(port, zeit: 1)
        XCTAssertThrowsError(try s.befehl(lun: 0, cdb: [0x5A, 0x08, 0x3A, 0x03, 0, 0, 0, 0x03, 0x60, 0], lesen: 864), "Gate stoppt 864 vor dem Senden")
        XCTAssertTrue(ereignisse("befehl").isEmpty, "kein Byte erreichte das Ziel")
        XCTAssertEqual(try s.modeSense3A(lun: 0, unterseite: 0x03).count, 581)
    }
}
