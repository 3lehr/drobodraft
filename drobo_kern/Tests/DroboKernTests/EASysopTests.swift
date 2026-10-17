import XCTest
@testable import DroboKern

/// EA-Systembefehle nach Dashboard-Format (Ghidra-Dekompilat DDService64d 3.6.1, docs/PLAN_LUN_UND_TIMEMACHINE_2026-10-17.md).
/// Nur Bauen + Pruefen gegen iscsi_ziel.py; das Gate `ISCSISitzung.verbot` bleibt fuer jedes EA zu.
final class EASysopTests: XCTestCase {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// `iscsi_ziel.py --ea-check CDB:DATEN` -> "" (Dashboard-Format) oder Grund (Ziel wuerde neu starten).
    func ziel(_ s: EASysop) throws -> String {
        let skript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("iscsi_ziel.py").path
        let p = Process(); let aus = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", skript, "--ea-check", "\(hex(s.cdb)):\(hex(s.daten))"]
        p.standardOutput = aus; try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: aus.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testBytesWieDekompilat() {
        // resizeLUNS @0x1000a7f78 -> sendSystemOperation(EhtPh) @0x1000a350e: txn Byte 4, Byte 6 0x21, Len 4
        XCTAssertEqual(EASysop.lunGroesse(txn: 5, tb: 16), EASysop(cdb: [0xEA, 0x10, 0x00, 0x0F, 0x05, 0x00, 0x21, 0x00, 0x04, 0x00], daten: [0, 0, 0, 16], lesen: 0))
        // CreateLUN @0x10006654e: CDB(1,0x12,0,0,1,1,0xc); htonll(Size), Flags, 0, BE16 LUN-ID
        XCTAssertEqual(EASysop.lunAnlegen(id: 3, groesse: 0x1000, flags: 1),
                       EASysop(cdb: [0xEA, 0x10, 0x00, 0x12, 0x00, 0x00, 0x21, 0x00, 0x0C, 0x00], daten: [0, 0, 0, 0, 0, 0, 0x10, 0, 1, 0, 0, 3], lesen: 0))
        // DeleteUniqueLUN @0x100064008: CDB(1,0x13,0,0,1,1,4); BE16 ID, u8 (LUN+0x68), 0
        XCTAssertEqual(EASysop.lunLoeschen(id: 0x0102, kennung: 7), EASysop(cdb: [0xEA, 0x10, 0x00, 0x13, 0x00, 0x00, 0x21, 0x00, 0x04, 0x00], daten: [1, 2, 7, 0], lesen: 0))
        // getNextUniqueLUNID @0x1000a901a: Typ 0 (Daten ein) -> Byte 2 0x80, Arg 0, Len 2
        XCTAssertEqual(EASysop.naechsteLunID(), EASysop(cdb: [0xEA, 0x10, 0x80, 0x20, 0x00, 0x00, 0x21, 0x00, 0x02, 0x00], daten: [], lesen: 2))
        // identifyESA(Ej) @0x1000a7f52: sendSystemOperation(6, Len 4)
        XCTAssertEqual(EASysop.identifizieren(txn: 9, wert: 4), EASysop(cdb: [0xEA, 0x10, 0x00, 0x06, 0x09, 0x00, 0x21, 0x00, 0x04, 0x00], daten: [0, 0, 0, 4], lesen: 0))
    }

    func testZielAkzeptiertDashboardFormat() throws {
        for s in [EASysop.lunGroesse(txn: 1, tb: 16), .lunAnlegen(id: 2, groesse: 1 << 40, flags: 0), .lunLoeschen(id: 2, kennung: 1), .naechsteLunID(), .identifizieren(txn: 2, wert: 4)] {
            XCTAssertEqual(try ziel(s), "", hex(s.cdb))
        }
    }

    func testZielLehntGemessenesAltformatAb() throws {
        // gesendet 2026-10-17 (Neustart): txn in Byte 5, Byte 6 0x20, Ctl != 0, Len 1
        let alt = EASysop(cdb: [0xEA, 0x10, 0x00, 0x06, 0x00, 0x01, 0x20, 0x00, 0x01, 0xC0], daten: [0], lesen: 0)
        XCTAssertNotEqual(try ziel(alt), "")
        var s = EASysop.lunGroesse(txn: 1, tb: 16); s.daten = [0, 16]
        XCTAssertNotEqual(try ziel(s), "", "Laenge != Daten")
        s = .naechsteLunID(); s.cdb[2] = 0
        XCTAssertNotEqual(try ziel(s), "", "lesend ohne 0x80")
    }

    func testGateBleibtZuFuerJedenGebautenBefehl() {
        for s in [EASysop.lunGroesse(txn: 1, tb: 16), .lunAnlegen(id: 2, groesse: 1, flags: 0), .lunLoeschen(id: 2, kennung: 1), .naechsteLunID(), .identifizieren(txn: 2, wert: 4)] {
            XCTAssertNotNil(ISCSISitzung.verbot(cdb: s.cdb, schreiben: s.daten.count, lesen: s.lesen))
        }
    }
}
