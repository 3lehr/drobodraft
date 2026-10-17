import XCTest
@testable import DroboKern

/// LUN-Verwaltung der DroboPro: Seiten 04/07 (echte Rohbytes aus iscsi_ziel.py), EA-Sperre, Verzeichnis, Schutz vor eingehaengten LUNs.
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

    // MARK: EA gesperrt (Messbefund 2026-10-17: jeder EA-Systembefehl startet die DroboPro neu)

    func ea(_ txn: UInt8 = 1) -> [UInt8] { [0xEA, 0x10, 0x00, 0x0F, 0x00, txn, 0x21, 0x00, 0x04, 0x00] }

    func testGateLehntJedenEABefehlAb() {
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: ea(), schreiben: 4, lesen: 0), "frueher erlaubte LUN-Groesse")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: ea(9), schreiben: 4, lesen: 0))
        for op in [UInt8](arrayLiteral: 0x02, 0x03, 0x05, 0x06, 0x0D, 0x0F, 0x10, 0x17, 0x70, 0x80) {
            var c = ea(); c[3] = op
            for (s, l) in [(4, 0), (0, 0), (0, 4), (5, 0)] { XCTAssertEqual(ISCSISitzung.verbot(cdb: c, schreiben: s, lesen: l)?.hasPrefix("0xea: system commands"), true, "EA op \(op) \(s)/\(l)") }
        }
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: [0xEA], schreiben: 0, lesen: 0)); XCTAssertNotNil(ISCSISitzung.verbot(cdb: Array(ea().dropLast()), schreiben: 4, lesen: 0))
    }

    func testEAErreichtDasZielNie() throws {
        let s = try sitzung(try ziel())
        for c in [ea(), [0xEA, 0x10, 0x00, 0x06, 0x00, 1, 0x20, 0x00, 0x01, 0x00], [0xEA, 0x10, 0x00, 0x03, 0x00, 1, 0x20, 0x00, 0x01, 0x00]] {
            XCTAssertThrowsError(try s.befehl(lun: 0, cdb: c, daten: c[8] == 4 ? [0, 0, 0, 4] : [])) { guard case ISCSIFehler.verboten(let t) = $0 else { return XCTFail("\($0)") }; XCTAssertTrue(t.contains("blocked"), t) }
        }
        XCTAssertTrue(ereignisse("befehl").allSatisfy { ($0["op"] as? Int) != 0xEA }, "EA erreichte das Ziel nicht"); XCTAssertTrue(ereignisse("lunsize").isEmpty)
    }

    // MARK: CLI-Ablauf und Verzeichnis

    func testLunGroesseVerweigertOhneNetzkontaktUndOhneDatei() throws {
        let port = try ziel()
        do {
            XCTAssertThrowsError(try iscsiLunGroesse()) {
                guard case ISCSIFehler.verboten(let t) = $0 else { return XCTFail("\($0)") }; XCTAssertTrue(t.contains("system commands to the DroboPro are blocked"), t)
            }
        }
        XCTAssertTrue(log().isEmpty, "Ziel nicht kontaktiert"); XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/s"))
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

/// Adresswechsel der DroboPro: Wiederfinden ueber die feste IQN.
extension ISCSITests {
    func testAdresseUeberIQNWiedergefunden() throws {
        let port = try ziel(["--iqn", "iqn.2026-10.local.test:drobopro.eins"])
        let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: 5); let iqn = try XCTUnwrap(d.ziele().first?.name); d.abmelden()
        func frage(_ h: String) throws -> String? { h == "127.0.0.1" ? iqn : nil }
        XCTAssertEqual(netzAdresseSuchen(iqn: iqn, lanHosts: { _ in ["192.0.2.1", "127.0.0.1"] }, iqnFuer: frage), "127.0.0.1", "alte Adresse tot, neue Adresse traegt dieselbe IQN")
    }

    func testFalscheOderFehlendeIQNSchreibtNichtUm() throws {
        let port = try ziel()
        let d = try ISCSISitzung(host: "127.0.0.1", port: port, zeitgrenze: 5); let iqn = try XCTUnwrap(d.ziele().first?.name); d.abmelden()
        func frage(_ h: String) throws -> String? { iqn }
        XCTAssertNil(netzAdresseSuchen(iqn: "iqn.2005-06.com.datarobotics:drobopro.andere", lanHosts: { _ in ["127.0.0.1"] }, iqnFuer: frage), "anderes Geraet (andere IQN): nie uebernehmen")
        XCTAssertNil(netzAdresseSuchen(iqn: "", lanHosts: { _ in ["127.0.0.1"] }, iqnFuer: frage), "leere IQN: nichts suchen")
        XCTAssertNil(netzAdresseSuchen(iqn: iqn, lanHosts: { _ in throw ISCSIFehler.protokoll("scan failed") }, iqnFuer: frage), "Suche fehlgeschlagen")
        XCTAssertNil(netzAdresseSuchen(iqn: iqn, lanHosts: { _ in ["192.0.2.7"] }, iqnFuer: { _ in nil }), "Fund ohne IQN")
    }

    func testNetzZielAlterEintragOhneIQNLaesstSichDecodieren() throws {
        let alt = Data(#"{"host":"192.168.1.5","lun":1}"#.utf8)
        let z = try JSONDecoder().decode(NetzZiel.self, from: alt)
        XCTAssertEqual(z, NetzZiel(host: "192.168.1.5", lun: 1)); XCTAssertNil(z.iqn); XCTAssertNil(z.luns)
        let neu = NetzZiel(host: "h", lun: 0, iqn: "iqn.x", luns: [NetzLunEintrag(lun: 0, uuid: "ab", name: "A")])
        XCTAssertEqual(try JSONDecoder().decode(NetzZiel.self, from: JSONEncoder().encode(neu)), neu)
    }
}
