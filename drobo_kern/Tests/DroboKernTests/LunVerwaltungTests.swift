import XCTest
@testable import DroboKern

/// LUN-Verwaltung der DroboPro: Seiten 04/07 (echte Rohbytes aus iscsi_ziel.py), Gate fuer EA 10 0F, LUN-Groesse gegen das Python-Ziel, Verzeichnis, Schutz vor eingehaengten LUNs.
extension ISCSITests {
    func seite(_ n: String) throws -> [UInt8] {
        let t = try String(contentsOfFile: #filePath.replacingOccurrences(of: "DroboKernTests/LunVerwaltungTests.swift", with: "iscsi_ziel.py"), encoding: .utf8)
        let h = t.components(separatedBy: "\(n): \"")[1].components(separatedBy: "\"")[0]
        return stride(from: 0, to: h.count, by: 2).map { UInt8(h[h.index(h.startIndex, offsetBy: $0)..<h.index(h.startIndex, offsetBy: $0 + 2)], radix: 16)! }
    }

    func testSeite07EchteBytes() throws {
        let l = try XCTUnwrap(lunSeite07(try seite("0x07")))
        XCTAssertEqual(l.count, 2, "Anzahl 2: die sechs Fuellsaetze (LUN 2-7) werden nicht geliefert")
        XCTAssertEqual(l.map(\.lun), [0, 1]); XCTAssertEqual(l[0].groesse, 16 << 40); XCTAssertEqual(l[1].groesse, 16 << 40)
        XCTAssertEqual(l.map(\.schemaText), ["GPT", "GPT"]); XCTAssertEqual(l.map(\.partitionen), [1, 1]); XCTAssertEqual(l.map(\.format), [0x40, 0x40])
        XCTAssertEqual(l.map(\.kennung), [1000, 1001])
    }

    func testSeite04EchteBytesNurErsterSatzGefuellt() throws {
        let l = try XCTUnwrap(lunSeite04(try seite("0x04")))
        XCTAssertEqual(l, [LunSeite04(lun: 0, gesamt: 17_892_759_306_240, benutzt: 994_886_991_872)], "LUN 1 ist in Seite 04 leer (gemessen)")
    }

    func testSeiteAbgelehnt() throws {
        var b = try seite("0x07")
        XCTAssertNil(lunSeite07(Array(b[0..<40])), "abgeschnitten")
        XCTAssertNil(lunSeite07([])); XCTAssertNil(lunSeite07([0x7B, 0x04, 0, 0, 0]), "kein 0x7A")
        b[6] = 16; XCTAssertNil(lunSeite07(b), "Satzlaenge != 17")
        b = try seite("0x07"); b[4] = 9; XCTAssertNil(lunSeite07(b), "mehr als 8 Saetze")
    }

    // MARK: EA 10 0F (LUN-Groesse)

    func ea(_ txn: UInt8 = 1) -> [UInt8] { [0xEA, 0x10, 0x00, 0x0F, 0x00, txn, 0x21, 0x00, 0x04, 0x00] }

    func testGateEAnurExakterLUNGroessenBefehl() {
        XCTAssertNil(ISCSISitzung.verbot(cdb: ea(), schreiben: 4, lesen: 0))
        XCTAssertNil(ISCSISitzung.verbot(cdb: ea(9), schreiben: 4, lesen: 0), "Transaktionsnummer beliebig")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: ea(), schreiben: 0, lesen: 0), "ohne Daten nie (DroboPro startet neu)")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: ea(), schreiben: 5, lesen: 0)); XCTAssertNotNil(ISCSISitzung.verbot(cdb: ea(), schreiben: 4, lesen: 4))
        for op in [UInt8](arrayLiteral: 0x02, 0x03, 0x05, 0x06, 0x0D, 0x10, 0x17, 0x70, 0x80) {   // Format, Neustart, Absturz, Blinken, Standby, Partition, Ausschalten, Firmware
            var c = ea(); c[3] = op; XCTAssertNotNil(ISCSISitzung.verbot(cdb: c, schreiben: 4, lesen: 0), "EA op \(op)")
        }
        var c = ea(); c[6] = 0x20; XCTAssertNotNil(ISCSISitzung.verbot(cdb: c, schreiben: 4, lesen: 0)); c = ea(); c[8] = 5; XCTAssertNotNil(ISCSISitzung.verbot(cdb: c, schreiben: 4, lesen: 0))
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: Array(ea().dropLast()), schreiben: 4, lesen: 0))
    }

    func testEAOhneFreigabeNieGesendet() throws {
        let port = try ziel()
        let s = try sitzung(port)
        XCTAssertThrowsError(try s.befehl(lun: 0, cdb: ea(), daten: [0, 0, 0, 4])) { guard case ISCSIFehler.verboten(let t) = $0 else { return XCTFail("\($0)") }; XCTAssertTrue(t.contains("not enabled"), t) }
        XCTAssertTrue(ereignisse("befehl").allSatisfy { ($0["op"] as? Int) != 0xEA }, "EA erreichte das Ziel nicht")
    }

    func testLUNGroesseSetzenSendetDatenImCommandPDU() throws {
        let port = try ziel()
        let s = try sitzung(port)
        let a = try s.lunGroesseSetzen(tib: 4)
        XCTAssertEqual(a.status, 0)
        let e = ereignisse("lunsize"); XCTAssertEqual(e.count, 1, "\(log())"); XCTAssertEqual(e[0]["tib"] as? Int, 4)
        XCTAssertEqual(e[0]["cdb"] as? String, "ea10000f000121000400000000000000", "genau der freigegebene CDB (auf 16 Byte aufgefuellt)")
        XCTAssertTrue(ereignisse("ABSTURZ ea-ohne-immediate").isEmpty)
        XCTAssertThrowsError(try s.befehl(lun: 0, cdb: ea(), daten: [0, 0, 0, 4]), "Freigabe gilt nur waehrend lunGroesseSetzen")
    }

    func testLUNGroesseOhneImmediateNieGesendet() throws {
        let port = try ziel(["--refuse-immediate"])
        let s = try sitzung(port)
        XCTAssertThrowsError(try s.lunGroesseSetzen(tib: 4)) { guard case ISCSIFehler.verboten(let t) = $0 else { return XCTFail("\($0)") }; XCTAssertTrue(t.contains("ImmediateData"), t) }
        XCTAssertTrue(ereignisse("lunsize").isEmpty); XCTAssertTrue(ereignisse("ABSTURZ ea-ohne-immediate").isEmpty, "das Ziel haette sonst neu gestartet")
        XCTAssertTrue(ereignisse("befehl").allSatisfy { ($0["op"] as? Int) != 0xEA })
    }

    func testLUNGroesseGrenzen() throws {
        let port = try ziel()
        let s = try sitzung(port)
        for t in [0, -1, 17, 100] { XCTAssertThrowsError(try s.lunGroesseSetzen(tib: t), "\(t)") }
        XCTAssertTrue(ereignisse("lunsize").isEmpty)
    }

    // MARK: CLI-Ablauf und Verzeichnis

    func testLunGroesseMitEingehaengterLUNVerweigert() throws {
        let port = try ziel()
        XCTAssertThrowsError(try iscsiLunGroesse(host: "127.0.0.1", port: port, tib: 4, ausfuehren: true, sicherungsordner: dir + "/s", eingehaengt: { [1] }, meldung: { _ in })) { guard case ISCSIFehler.verboten = $0 else { return XCTFail("\($0)") } }
        XCTAssertTrue(log().isEmpty, "Ziel nicht kontaktiert"); XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/s"))
    }

    func testLunGroesseTrockenlaufSichertZustandUndSendetNichts() throws {
        let port = try ziel(); var m: [String] = []
        try iscsiLunGroesse(host: "127.0.0.1", port: port, tib: 4, ausfuehren: false, sicherungsordner: dir + "/s", eingehaengt: { [] }, meldung: { m.append($0) })
        XCTAssertTrue(m.contains { $0.hasPrefix("dry run") }); XCTAssertTrue(ereignisse("lunsize").isEmpty)
        let f = try FileManager.default.contentsOfDirectory(atPath: dir + "/s"); XCTAssertEqual(f.count, 1)
        let t = try String(contentsOfFile: dir + "/s/" + f[0], encoding: .utf8)
        for k in ["3A/01", "3A/02", "3A/04", "3A/07", "3A/09", "luns: [0, 1]"] { XCTAssertTrue(t.contains(k), k) }
    }

    func testLunGroesseAusfuehren() throws {
        let port = try ziel(); var m: [String] = []
        try iscsiLunGroesse(host: "127.0.0.1", port: port, tib: 4, ausfuehren: true, sicherungsordner: dir + "/s", wartenMax: 6, eingehaengt: { [] }, meldung: { m.append($0) })
        XCTAssertEqual(ereignisse("lunsize").first?["tib"] as? Int, 4)
        XCTAssertTrue(m.contains { $0.hasPrefix("EA 0F answered") && $0.contains("status 0") }, "\(m)")
        XCTAssertTrue(m.contains { $0.hasPrefix("after: 3A/07") }, "Zustand nach der Aenderung gelesen")
    }

    func testVerzeichnisMitMehrerenLUNs() throws {
        let port = try ziel(mib: 8)
        let s = try sitzung(port)
        let v = try netzLunVerzeichnis(sitzung: s)
        XCTAssertEqual(v.map(\.lun), [0, 1]); XCTAssertEqual(v.map(\.groesse), [8 << 20, 8 << 20]); XCTAssertEqual(v.map(\.schema), ["GPT", "GPT"], "Schema aus Seite 07")
        XCTAssertEqual(v.map(\.hatDateisystem), [false, false], "leere Abbilder: kein HFS+")
    }

    func testNurDerISCSIWegKannEASenden() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let dateien = FileManager.default.enumerator(at: src, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(dateien.count, 20)
        for f in dateien where !["ISCSIBefehle.swift", "ISCSIGroesse.swift", "main.swift"].contains(f.lastPathComponent) {
            let t = try String(contentsOf: f, encoding: .utf8).lowercased()
            XCTAssertFalse(t.contains("0xea"), "\(f.lastPathComponent): EA-Opcode ausserhalb des iSCSI-Gates (USB/Dext-Weg darf ihn nie senden)")
        }
    }
}
