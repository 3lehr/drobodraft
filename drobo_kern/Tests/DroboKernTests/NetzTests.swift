import XCTest
@testable import DroboKern

/// Netzwerk-Drobo: Seitendekodierung (Rohbytes von der echten DroboPro, ohne Seriennummern), Statusseiten und Metadaten-Sicherung gegen das Python-Ziel.
final class NetzTests: XCTestCase {
    func bytes(_ h: String) -> [UInt8] { stride(from: 0, to: h.count, by: 2).map { UInt8(h[h.index(h.startIndex, offsetBy: $0)..<h.index(h.startIndex, offsetBy: $0 + 2)], radix: 16)! } }

    func testGateExakteLaengen() {
        func cdb(_ sub: UInt8, _ al: Int) -> [UInt8] { [0x5A, 0x08, 0x3A, sub, 0, 0, 0, UInt8(al >> 8), UInt8(al & 0xff), 0] }
        for (sub, n) in ISCSISitzung.modeSenseExakt { XCTAssertNil(ISCSISitzung.verbot(cdb: cdb(sub, n), schreiben: 0, lesen: n), "sub \(sub)"); XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(sub, n - 1), schreiben: 0, lesen: n - 1)); XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(sub, n + 1), schreiben: 0, lesen: n + 1)) }
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x04, 512), schreiben: 0, lesen: 512), "04 braucht genau 157")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x03, 4096), schreiben: 0, lesen: 4096))
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x35, 512), schreiben: 0, lesen: 512), "35 (SlotInfo2) nur mit exakter Laenge: Kopf 12 + 8 Schaechte x 108")
        XCTAssertEqual(ISCSISitzung.modeSenseExakt[0x35], 12 + 8 * 108)
        XCTAssertNil(ISCSISitzung.verbot(cdb: cdb(0x01, 512), schreiben: 0, lesen: 512), "bisheriges Verhalten bleibt")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x31, 100), schreiben: 0, lesen: 100))
    }

    func testSchaechteAusDroboProSeite03() throws {
        let h = try String(contentsOfFile: #filePath.replacingOccurrences(of: "DroboKernTests/NetzTests.swift", with: "iscsi_ziel.py"), encoding: .utf8)
        let hex = h.components(separatedBy: "0x03: \"")[1].components(separatedBy: "\"")[0]
        let s = droboProSchaechte(bytes(hex))
        XCTAssertEqual(s.count, 8)
        XCTAssertEqual(s[0].nr, 1); XCTAssertEqual(s[0].kapazitaet, 8_001_563_222_016); XCTAssertEqual(s[0].modell, "ST8000DM004-2CX188"); XCTAssertEqual(s[0].farbe, .gruen)
        XCTAssertEqual(s[6].farbe, .leer); XCTAssertFalse(s[6].belegt); XCTAssertEqual(s[7].nr, 8); XCTAssertEqual(s[4].kapazitaet, 3_000_592_982_016)
        XCTAssertTrue(droboProSchaechte([0x7A, 0x03]).isEmpty); XCTAssertTrue(droboProSchaechte([]).isEmpty)
    }
}
