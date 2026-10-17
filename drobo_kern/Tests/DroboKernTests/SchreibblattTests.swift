import XCTest
@testable import DroboKern

final class SchreibblattTests: XCTestCase {
    let z = BestaetigteKombination(build: 22137, anschluss: .iscsiWLAN)
    func art(erprobt: Bool = true, zuletzt: BestaetigteKombination? = nil, build: Int? = 22137, a: Anschluss = .iscsiWLAN, weg: Int = schreibwegVersion, unsauber: Bool = false) -> BlattArt {
        schreibBlattArt(erprobt: erprobt, zuletzt: zuletzt, build: build, anschluss: a, schreibweg: weg, unsauber: unsauber)
    }
    func testErstmals_Voll15() { XCTAssertEqual(art(), .voll(.erstmals)); XCTAssertEqual(art().sperre, 15) }
    func testWiederholungGleicheKombination_Kurz_KeineSperre() { XCTAssertEqual(art(zuletzt: z), .kurz); XCTAssertEqual(art(zuletzt: z).sperre, 0) }
    func testFirmwareGeaendert_Voll() { XCTAssertEqual(art(zuletzt: z, build: 22138), .voll(.firmware)); XCTAssertEqual(art(zuletzt: z, build: nil), .voll(.firmware)) }
    func testAnschlussGeaendert_Voll() { XCTAssertEqual(art(zuletzt: z, a: .iscsiKabel), .voll(.anschluss)) }
    func testSchreibwegGeaendert_Voll() { XCTAssertEqual(art(zuletzt: z, weg: schreibwegVersion + 1), .voll(.schreibweg)); XCTAssertEqual(art(zuletzt: z, weg: schreibwegVersion - 1), .voll(.schreibweg)) }
    func testUnsauberBeendet_Voll() { XCTAssertEqual(art(zuletzt: z, unsauber: true), .voll(.unsauber)) }
    func testNichtErprobt_ImmerVoll_auchBeiGleicherBestaetigung() {
        XCTAssertEqual(art(erprobt: false, zuletzt: z), .voll(.nichtErprobt)); XCTAssertEqual(art(erprobt: false), .voll(.nichtErprobt))
    }
    func testBuildUnbekanntGleichBlieb_Kurz() { let u = BestaetigteKombination(build: nil, anschluss: .usb); XCTAssertEqual(art(zuletzt: u, build: nil, a: .usb), .kurz) }
    func testBestaetigteKombination_Codable() throws {
        let d = try JSONEncoder().encode(["k": z]); XCTAssertEqual(try JSONDecoder().decode([String: BestaetigteKombination].self, from: d)["k"], z)
    }

    func testSperreRest_Grenzen() {
        let s = Date(timeIntervalSince1970: 1_000)
        func r(_ dt: Double) -> Int { sperreRest(start: s, dauer: 15, jetzt: s.addingTimeInterval(dt)) }
        XCTAssertEqual(r(0), 15); XCTAssertEqual(r(0.1), 15); XCTAssertEqual(r(1), 14); XCTAssertEqual(r(14), 1); XCTAssertEqual(r(14.5), 1)
        XCTAssertEqual(r(14.999), 1, "noch nicht frei"); XCTAssertEqual(r(15), 0); XCTAssertEqual(r(15.001), 0); XCTAssertEqual(r(3600), 0)
        XCTAssertEqual(r(-100), 15, "zurueckgestellte Uhr: nie mehr als die Dauer")
        XCTAssertEqual(sperreRest(start: s, dauer: 0, jetzt: s), 0)
    }
}
