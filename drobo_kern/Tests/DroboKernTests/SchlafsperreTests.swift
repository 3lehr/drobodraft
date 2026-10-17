import XCTest
@testable import DroboKern

/// Energie: Assertion an/aus ueber den austauschbaren Wrapper; Freigabe auch bei Fehler (Rotprobe: ohne defer bliebe sie stehen).
final class SchlafsperreTests: XCTestCase {
    final class Protokoll: @unchecked Sendable { var z: [String] = []
        var api: SchlafsperreAPI { SchlafsperreAPI(anlegen: { self.z.append("an \($0)"); return 7 }, loesen: { self.z.append("aus \($0)") }) } }
    struct Fehlschlag: Error {}

    func testAnUndAusUmDieArbeit() async throws {
        let p = Protokoll()
        let r = try await mitSchlafsperre("DroboDraft: Formatieren DroboPro", api: p.api) { p.z.append("arbeit"); return 42 }
        XCTAssertEqual(r, 42); XCTAssertEqual(p.z, ["an DroboDraft: Formatieren DroboPro", "arbeit", "aus 7"])
    }
    func testFreigabeAuchBeiFehler() async {
        let p = Protokoll()
        do { try await mitSchlafsperre("x", api: p.api) { throw Fehlschlag() }; XCTFail("Fehler muss durchgehen") } catch { XCTAssertTrue(error is Fehlschlag) }
        XCTAssertEqual(p.z, ["an x", "aus 7"], "Freigabe trotz Fehler")
    }
    func testAnlegenGescheitertKeineFreigabeUndArbeitLaeuft() async throws {
        var z: [String] = []
        let api = SchlafsperreAPI(anlegen: { _ in nil }, loesen: { z.append("aus \($0)") })
        let r = try await mitSchlafsperre("x", api: api) { 1 }
        XCTAssertEqual(r, 1); XCTAssertEqual(z, [])
    }
    func testEchteAssertionImSystem() async throws {
        let (rc, vorher) = ausfuehren("/usr/bin/pmset", ["-g", "assertions"]); XCTAssertEqual(rc, 0)
        XCTAssertFalse(vorher.contains("DroboDraft: Test-Vorgang"))
        let waehrend = try await mitSchlafsperre("DroboDraft: Test-Vorgang") { ausfuehren("/usr/bin/pmset", ["-g", "assertions"]).1 }
        XCTAssertTrue(waehrend.contains("DroboDraft: Test-Vorgang"), "Assertion im System sichtbar")
        XCTAssertFalse(ausfuehren("/usr/bin/pmset", ["-g", "assertions"]).1.contains("DroboDraft: Test-Vorgang"), "danach weg")
    }
}
