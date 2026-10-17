import XCTest
@testable import DroboKern

/// Gesamtzustand: Werte der Drobo 5C vom 2026-10-16 (echte Rohbytes aus DroboFixture) und der DroboPro (0x28000, 0,99 von 17,88 TB), Grenzwerte an den Schwellen.
final class GesamtzustandTests: XCTestCase {
    func fuenfC() throws -> DroboStatus { try XCTUnwrap(decodiereDroboStatus(DroboFixture.dict())) }

    /// Synthetischer Status: nur Prozent steuern (Bits 0, alle Schaechte gruen), Gesamt 1000 -> belegt = Prozent * 10.
    func prozent(_ p: Int, bits: UInt32 = 0, schaechte: [SchachtFarbe] = [.gruen, .gruen]) -> DroboStatus {
        let k = DroboKapazitaet(frei: UInt64(1000 - p * 10), benutzt: UInt64(p * 10), gesamtGeschuetzt: 1000, gesamtUngeschuetzt: 1500)
        let sc = schaechte.enumerated().map { Schacht(nr: $0.offset + 1, farbe: $0.element, fehler: 0, modell: "X", kapazitaet: 1, temperatur: nil, restleben: nil) }
        return DroboStatus(zeit: Date(), ok: true, fehler: "", modell: "T", firmware: "", firmwareBuild: nil, protokoll: nil, schaechte: sc, kapazitaet: k, statusBits: bits,
                           relayout: 0, meldungen: [], schwere: .ok, unbelegt: [:])
    }

    func test5CVom16Oktober_PlatzWirdKnapp_Schacht1Tauschen() throws {
        let g = gesamtzustand(try fuenfC(), pruefungOK: true)
        XCTAssertEqual(g.stufe, .warnung); XCTAssertEqual(g.schlagzeile, .platzKnapp); XCTAssertEqual(g.empfehlung, .schachtTauschen(1))
        XCTAssertEqual(g.schutz, .aktiv)
        XCTAssertEqual(g.belegtProzent, 93, "63,5 von 67,8 TB: 93,7 % belegt, abgerundet")   // 94 % gerundet im Plan; abgerundet, damit Anzeige und Schwelle zusammenpassen
        XCTAssertEqual(Double(g.frei) / 1e12, 4.25, accuracy: 0.01)
    }

    func testDroboProVergleichswerte_InOrdnung() throws {
        var s = try fuenfC()   // Rahmen der 5C, Werte der DroboPro darueber: 0x28000, 0,99 TB belegt von 17,88 TB, alle Schaechte gruen
        s.statusBits = 0x28000; s.schaechte = s.schaechte.map { var x = $0; x.farbe = .gruen; return x }
        s.kapazitaet = DroboKapazitaet(frei: 16_890_000_000_000, benutzt: 990_000_000_000, gesamtGeschuetzt: 17_880_000_000_000, gesamtUngeschuetzt: 18_000_000_000_000)
        s.meldungen = [Meldung(bit: 0x28000, text: "Weitere Meldung der Drobo", schwere: .ok)]; s.schwere = .ok
        let g = gesamtzustand(s, pruefungOK: true)
        XCTAssertEqual(g.stufe, .ok); XCTAssertEqual(g.schlagzeile, .inOrdnung); XCTAssertEqual(g.empfehlung, .keine); XCTAssertEqual(g.belegtProzent, 5)
    }

    func testGelbGrenzwert84_85_86() {
        XCTAssertEqual(gesamtzustand(prozent(84)).stufe, .ok)
        XCTAssertEqual(gesamtzustand(prozent(84)).schlagzeile, .inOrdnung)
        for p in [85, 86] { let g = gesamtzustand(prozent(p)); XCTAssertEqual(g.stufe, .warnung, "\(p)"); XCTAssertEqual(g.schlagzeile, .platzKnapp); XCTAssertEqual(g.empfehlung, .platzSchaffen) }
    }

    func testRotGrenzwert94_95_96() {
        XCTAssertEqual(gesamtzustand(prozent(94)).stufe, .warnung)
        for p in [95, 96] { let g = gesamtzustand(prozent(p)); XCTAssertEqual(g.stufe, .kritisch, "\(p)"); XCTAssertEqual(g.schlagzeile, .platzSehrKnapp) }
    }

    func testEigeneSchwellenVonSeite30() {
        XCTAssertEqual(gesamtzustand(prozent(79), gelbProzent: 80, rotProzent: 90).stufe, .ok)
        XCTAssertEqual(gesamtzustand(prozent(80), gelbProzent: 80, rotProzent: 90).stufe, .warnung)
        XCTAssertEqual(gesamtzustand(prozent(90), gelbProzent: 80, rotProzent: 90).stufe, .kritisch)
    }

    func testGeraetBitsGewinnenAuchBeiWenigBelegung() {
        XCTAssertEqual(gesamtzustand(prozent(10, bits: 0x4)).schlagzeile, .platzKnapp, "Bit 0x4 = Gelb-Schwelle laut Drobo")
        XCTAssertEqual(gesamtzustand(prozent(10, bits: 0x2)).stufe, .kritisch)
    }

    func testDefektePlatteGehtVorPlatz() {
        let g = gesamtzustand(prozent(96, schaechte: [.gruen, .gruen, .rot]))
        XCTAssertEqual(g.schlagzeile, .plattenDefekt); XCTAssertEqual(g.empfehlung, .schachtTauschen(3)); XCTAssertEqual(g.stufe, .kritisch)
    }

    func testRelayoutUndKeineRedundanzUndDateisystem() {
        XCTAssertEqual(gesamtzustand(prozent(10, bits: 0x200)).schlagzeile, .redundanzWirdHergestellt)
        XCTAssertEqual(gesamtzustand(prozent(10, bits: 0x200)).schutz, .wirdHergestellt)
        XCTAssertEqual(gesamtzustand(prozent(10, bits: 0x40)).schutz, .keiner)
        let g = gesamtzustand(prozent(10), pruefungOK: false)
        XCTAssertEqual(g.schlagzeile, .dateisystemAuffaellig); XCTAssertEqual(g.empfehlung, .dateisystemPruefen); XCTAssertEqual(g.stufe, .warnung)
        XCTAssertEqual(gesamtzustand(prozent(10), pruefungOK: nil).stufe, .ok, "keine Pruefung bekannt = kein Urteil")
    }

    func testOhneKapazitaetKeinFuellstand() {
        var s = prozent(10); s.kapazitaet = nil
        let g = gesamtzustand(s); XCTAssertNil(g.belegtProzent); XCTAssertEqual(g.stufe, .ok)
    }

    func testAufteilungBelegtFreiReserviert() {
        let g = gesamtzustand(prozent(40)); XCTAssertEqual(g.belegt, 400); XCTAssertEqual(g.frei, 600); XCTAssertEqual(g.reserviert, 500)
    }
}
