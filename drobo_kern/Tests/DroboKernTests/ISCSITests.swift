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
    func ziel(_ extra: [String] = []) throws -> UInt16 {
        for i in 0..<2 { FileManager.default.createFile(atPath: "\(dir)/lun\(i).img", contents: Data(count: 4 << 20)) }
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
        let z = try d.ziele(); XCTAssertEqual(z.first?.name, "iqn.2026-10.local.test:ziel"); d.abmelden()
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
        XCTAssertEqual(aus.count, 524288 / 2048)
        XCTAssertLessThanOrEqual(aus.map { $0["laenge"] as! Int }.max()!, 2048)
        XCTAssertTrue(ereignisse("verletzung").isEmpty)
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
}
