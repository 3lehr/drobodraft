import XCTest
@testable import DroboKern

final class DroboStatusTests: XCTestCase {
    func status(_ mod: ([String: Any]) -> [String: Any] = { $0 }) throws -> DroboStatus { try XCTUnwrap(decodiereDroboStatus(mod(DroboFixture.dict()))) }

    func testEchteRohbytesDekodiert() throws {
        let s = try status()
        XCTAssertEqual(s.modell, "5C Gen3"); XCTAssertEqual(s.protokoll, "0.11"); XCTAssertEqual(s.firmwareBuild, 50532); XCTAssertTrue(s.firmware.hasPrefix("Apr 16 2021"))
        XCTAssertEqual(s.schaechte.count, 5)
        XCTAssertEqual(s.schaechte.map(\.farbe), [.gelb, .gruen, .gruen, .gruen, .gruen])   // am Geraet geeicht: Schacht 1 gelb, 2-5 gruen
        XCTAssertEqual(s.schaechte.map(\.nr), [1, 2, 3, 4, 5])
        XCTAssertEqual(s.schaechte[0].kapazitaet, 16_000_900_661_248); XCTAssertEqual(s.schaechte[2].kapazitaet, 18_000_207_937_536)
        XCTAssertEqual(s.schaechte[0].modell, "ST16000NM001G-2K"); XCTAssertEqual(s.schaechte.map(\.fehler), [0, 0, 0, 0, 0])
        XCTAssertNil(s.schaechte[0].temperatur, "Temperatur 0 = nicht belegt"); XCTAssertEqual(s.schaechte[0].restleben, nil, "Typ 0 = kein SSD-Zaehler")
        let k = try XCTUnwrap(s.kapazitaet)   // Messwerte 2026-10-16: frei 4.25 TB, benutzt 63.54 TB, geschuetzt gesamt 67.79 TB
        XCTAssertEqual(Double(k.frei) / 1e12, 4.25, accuracy: 0.01); XCTAssertEqual(Double(k.benutzt) / 1e12, 63.54, accuracy: 0.01); XCTAssertEqual(Double(k.gesamtGeschuetzt) / 1e12, 67.79, accuracy: 0.01)
        XCTAssertEqual(k.freiAnteil, 0.0627, accuracy: 0.001)
        XCTAssertEqual(s.statusBits, 0x28004); XCTAssertEqual(s.relayout, 0)
        XCTAssertEqual(s.schwere, .warnung, "0x4 = Gelb-Schwelle = Warnung; Schacht 1 gelb")
        XCTAssertTrue(s.meldungen.contains { $0.bit == 0x4 && $0.schwere == .warnung })
        XCTAssertTrue(s.meldungen.contains { $0.text == "Weitere Meldung der Drobo" && $0.bit == 0x28000 }, "unbelegte Bits roh, ohne Urteil")
        XCTAssertEqual(s.zeit, Date(timeIntervalSince1970: 1792151779))
    }

    func testKeineSeriennummerInDerAusgabe() throws {
        let s = try status()
        let alles = "\(s)"
        for n in ["DUMMYSERIAL", "SERIAL0"] { XCTAssertFalse(alles.contains(n), "Seriennummer darf nie in die Ausgabe gelangen") }
    }

    func testSchweregradMaskenGrenzen() throws {
        func mitBits(_ b: UInt32) throws -> DroboStatus {
            try status { var d = $0; var p = [UInt8](d["p3A_09"] as! Data); for i in 0..<4 { p[4 + i] = UInt8(b >> UInt32(24 - 8 * i) & 0xFF) }; d["p3A_09"] = Data(p)
                var sl = [UInt8](d["p3A_35"] as! Data); sl[0xC + 1] = 3; d["p3A_35"] = Data(sl); return d }   // alle Schaechte gruen, damit nur die Bits wirken
        }
        XCTAssertEqual(try mitBits(0).schwere, .ok)
        XCTAssertEqual(try mitBits(0x4).schwere, .warnung)              // Gelb-Schwelle
        XCTAssertEqual(try mitBits(0x200).schwere, .warnung)           // Relayout laeuft
        XCTAssertEqual(try mitBits(0x2).schwere, .kritisch)            // Rot-Schwelle
        XCTAssertEqual(try mitBits(0x10).schwere, .kritisch)           // defekte Platte
        XCTAssertEqual(try mitBits(0x40).schwere, .kritisch)           // keine Redundanz
        XCTAssertEqual(try mitBits(0x8000).schwere, .ok)               // unbelegtes Bit: kein Urteil
        XCTAssertEqual(try mitBits(0x8000).meldungen.first?.text, "Weitere Meldung der Drobo")
        XCTAssertEqual(try mitBits(0x6).schwere, .kritisch, "kritisch schlaegt Warnung")
    }

    func testSchachtfarbenUndLeerUndRot() throws {
        let namen: [UInt8: SchachtFarbe] = [0: .aus, 1: .rot, 2: .gelb, 3: .gruen, 4: .rotGruen, 5: .rotGelb, 6: .rotAus, 0x80: .leer, 9: .unbekannt(9)]
        for (c, f) in namen { XCTAssertEqual(farbe(c), f) }
        let s = try status { var d = $0; var sl = [UInt8](d["p3A_35"] as! Data); sl[0xC + 0x6C + 1] = 1; d["p3A_35"] = Data(sl); return d }
        XCTAssertEqual(s.schaechte[1].farbe, .rot); XCTAssertEqual(s.schwere, .kritisch, "ein roter Schacht ist kritisch")
        let l = try status { var d = $0; var sl = [UInt8](d["p3A_35"] as! Data); sl[0xC + 0x6C * 4 + 1] = 0x80; d["p3A_35"] = Data(sl); return d }
        XCTAssertEqual(l.schaechte[4].farbe, .leer)
    }

    func testAlterUndAbgeschnitteneDaten() throws {
        let s = try status()
        XCTAssertEqual(s.alter(jetzt: s.zeit.addingTimeInterval(40)), 40); XCTAssertFalse(s.veraltet(jetzt: s.zeit.addingTimeInterval(150)))
        XCTAssertTrue(s.veraltet(jetzt: s.zeit.addingTimeInterval(151))); XCTAssertEqual(s.alter(jetzt: s.zeit.addingTimeInterval(-5)), 0)
        XCTAssertNil(decodiereDroboStatus([:]), "ohne Zeit kein Status")
        // abgeschnittene Slot-Seite: nur vollstaendige Saetze
        let k = try status { var d = $0; d["p3A_35"] = (d["p3A_35"] as! Data).prefix(0xC + 0x6C * 2 + 10); return d }
        XCTAssertEqual(k.schaechte.count, 2)
        let leer = try status { var d = $0; d["p3A_35"] = Data([0x7A]); d["p3A_02"] = Data(); return d }
        XCTAssertEqual(leer.schaechte.count, 0); XCTAssertNil(leer.kapazitaet)
    }

    func testRegistryOhneDextLiefertNil() {
        XCTAssertNil(liesDroboStatus(uuid: "11111111-2222-3333-4444-555555555555"))
    }
}
