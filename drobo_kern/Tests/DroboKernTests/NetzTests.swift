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
        for al in [4, 8, 512, 864, 868, 869, 872, 876, 1308] { XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x35, al), schreiben: 0, lesen: al), "35 an der DroboPro nie senden (Messbefund 2026-10-17), Laenge \(al)") }
        XCTAssertNil(ISCSISitzung.modeSenseExakt[0x35]); XCTAssertFalse(ISCSISitzung.modeSenseUnterseiten.contains(0x35))
        XCTAssertNil(ISCSISitzung.verbot(cdb: cdb(0x01, 512), schreiben: 0, lesen: 512), "bisheriges Verhalten bleibt")
        XCTAssertNotNil(ISCSISitzung.verbot(cdb: cdb(0x31, 100), schreiben: 0, lesen: 100))
    }

    func testSchaechteAusDroboProSeite03() throws {
        let h = try String(contentsOfFile: #filePath.replacingOccurrences(of: "DroboKernTests/NetzTests.swift", with: "iscsi_ziel.py"), encoding: .utf8)
        let hex = h.components(separatedBy: "0x03: \"")[1].components(separatedBy: "\"")[0]
        let s = droboProSchaechte(bytes(hex))
        XCTAssertEqual(s.count, 8)
        XCTAssertEqual(s.map(\.farbe), [.gruen, .gruen, .gruen, .gruen, .gruen, .gruen, .leer, .gruen], "am Geraet 2026-10-17: alle gruen ausser Schacht 7 (leer)")
        XCTAssertEqual(s.map(\.nr), Array(1...8)); XCTAssertEqual(s.filter(\.belegt).count, 7)
        XCTAssertEqual(s[0].nr, 1); XCTAssertEqual(s[0].kapazitaet, 8_001_563_222_016); XCTAssertEqual(s[0].modell, "ST8000DM004-2CX188"); XCTAssertEqual(s[0].farbe, .gruen)
        XCTAssertEqual(s[6].farbe, .leer); XCTAssertFalse(s[6].belegt); XCTAssertEqual(s[7].nr, 8); XCTAssertEqual(s[4].kapazitaet, 3_000_592_982_016)
        XCTAssertTrue(droboProSchaechte([0x7A, 0x03]).isEmpty); XCTAssertTrue(droboProSchaechte([]).isEmpty)
    }
}
