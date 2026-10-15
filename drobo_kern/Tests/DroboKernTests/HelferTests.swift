import XCTest
@testable import DroboKern

/// Dienstlogik ohne Root und ohne Geraet: Suche, Knoten und chown sind Attrappen; Freigabelisten liegen in einem Temp-Home.
final class HelferTests: XCTestCase {
    let U = "C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1"
    var home = ""
    var calls: [String] = []

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "helfer-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/Library/Containers/\(modulKennung)/Data", withIntermediateDirectories: true)
        calls = []
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }

    func liste(_ inhalt: String?) throws {
        let p = home + "/Library/Containers/\(modulKennung)/Data/freigabe.json"
        if let i = inhalt { try i.write(toFile: p, atomically: true, encoding: .utf8) }
    }
    let gut = #"[{"volume_uuid":"C2E343A1-0D4C-3B35-B5DC-0325C1E1E1B1","modus":"nurlesen","max_bytes":1}]"#

    func logik(bsd: String? = "disk9s2", art: mode_t = S_IFBLK, chownRC: Int32 = 0) -> HelferLogik {
        var l = HelferLogik()
        l.finden = { u in bsd.map { Medium(bsd: $0, uuid: u.uppercased(), groesse: 1) } }
        l.ordnerVon = { _ in self.home }
        l.knotenArt = { $0.hasPrefix("/dev/r") ? S_IFCHR : ($0.hasPrefix("/dev/") ? art : S_IFDIR) }
        l.chown = { p, u, g in self.calls.append("chown \(p) \(u):\(g)"); return chownRC }
        l.chmod = { p, m in self.calls.append("chmod \(p) \(String(m, radix: 8))"); return 0 }
        l.operatorGID = { 5 }
        return l
    }
    func abgelehnt(_ l: HelferLogik, uuid: String? = nil, _ teil: String, zurueck: Bool = false, line: UInt = #line) {
        do { if zurueck { try l.zurueckgeben(uuid ?? U, uid: 501) } else { try l.freigeben(uuid ?? U, uid: 501) }; XCTFail("haette abgelehnt werden muessen", line: line) }
        catch { XCTAssertTrue("\(error)".contains(teil), "\(error)", line: line) }
        XCTAssertEqual(calls, [], "bei Ablehnung darf nichts geaendert werden", line: line)
    }

    func testFreigebenChownAufDiskUndRdiskAnAufrufer() throws {
        try liste(gut)
        try logik().freigeben(U.lowercased(), uid: 501)
        XCTAssertEqual(calls, ["chown /dev/disk9s2 501:5", "chown /dev/rdisk9s2 501:5"])
    }
    func testZurueckgebenRootOperator0640() throws {
        try liste(gut)
        try logik().zurueckgeben(U, uid: 501)
        XCTAssertEqual(calls, ["chown /dev/disk9s2 0:5", "chmod /dev/disk9s2 640", "chown /dev/rdisk9s2 0:5", "chmod /dev/rdisk9s2 640"])
    }
    func testNichtInListeAbgelehnt() throws {
        try liste("[]"); abgelehnt(logik(), "nicht in der Freigabeliste")
        try liste(#"[{"volume_uuid":"11111111-1111-1111-1111-111111111111","modus":"nurlesen","max_bytes":1}]"#); abgelehnt(logik(), "nicht in der Freigabeliste")
    }
    func testFremdeUUIDAbgelehnt() throws {
        try liste(gut)
        abgelehnt(logik(), uuid: "22222222-2222-2222-2222-222222222222", "nicht in der Freigabeliste")
        abgelehnt(logik(), uuid: "22222222-2222-2222-2222-222222222222", "nicht in der Freigabeliste", zurueck: true)
    }
    func testFehlendeOderKaputteListeAbgelehnt() throws {
        abgelehnt(logik(), "nicht in der Freigabeliste")      // Datei fehlt
        try liste("{kaputt"); abgelehnt(logik(), "unbrauchbar")
        try liste(#"{"x":1}"#); abgelehnt(logik(), "unbrauchbar")
    }
    func testUngueltigeUUIDAbgelehnt() throws {
        try liste(gut)
        abgelehnt(logik(), uuid: "../../etc", "keine gueltige UUID")
        abgelehnt(logik(), uuid: "", "keine gueltige UUID")
    }
    func testWholeDiskAbgelehnt() throws {
        try liste(gut)
        abgelehnt(logik(bsd: "disk9"), "whole disk")
        abgelehnt(logik(bsd: "disk9", art: S_IFBLK), "whole disk", zurueck: true)
    }
    func testKeinVolumeAbgelehnt() throws {
        try liste(gut); abgelehnt(logik(bsd: nil), "kein Volume")
    }
    func testKeinGeraeteknotenAbgelehnt() throws {
        try liste(gut); abgelehnt(logik(art: S_IFLNK), "kein Geraeteknoten"); abgelehnt(logik(art: S_IFREG), "kein Geraeteknoten")
    }
    func testChownFehlerWirdGemeldet() throws {
        try liste(gut)
        XCTAssertThrowsError(try logik(chownRC: -1).freigeben(U, uid: 501))
    }
    func testAnforderungIstGueltigUndNimmtFremdeKennungNicht() {
        var req: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(helferAnforderung as CFString, [], &req), errSecSuccess)
        XCTAssertTrue(helferAnforderung.contains(teamID) && helferAnforderung.contains("\"\(appKennung)\"") && !helferAnforderung.contains("anchor trusted"))
    }
    func testTempHomeNichtEchtesHome() {
        XCTAssertFalse(home.hasPrefix(NSHomeDirectory()), "Temp-Home darf nicht das echte Home sein")
    }

    // MARK: Freigabeliste ueber den Dienst

    var listePfad: String { home + "/Library/Containers/\(modulKennung)/Data/freigabe.json" }
    func eintraege() throws -> [[String: Any]] { try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: listePfad))) as! [[String: Any]] }
    func listeMitEigner() -> HelferLogik {
        var l = logik(); l.datei = { _ in (501, 20) }; l.eigner = { p, u, g in self.calls.append("eigner \(p == self.listePfad) \(u):\(g)"); return 0 }; return l
    }
    let fremd = "11111111-1111-1111-1111-111111111111"

    func testLesen() throws {
        try liste(gut)
        XCTAssertEqual(try logik().freigabeLesen(U, uid: 501), "nurlesen")
        XCTAssertEqual(try logik().freigabeLesen(fremd, uid: 501), "")
    }
    func testLesenKaputtUndUngueltig() throws {
        try liste("{kaputt")
        XCTAssertThrowsError(try logik().freigabeLesen(U, uid: 501))
        XCTAssertThrowsError(try logik().freigabeLesen("../x", uid: 501))
    }
    func testSetzenNeuBehaeltAndereUndGibtDateiAnNutzerZurueck() throws {
        try liste(gut)
        try listeMitEigner().freigabeSetzen(fremd, modus: "schreiben", maxBytes: 99, uid: 501)
        let e = try eintraege()
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first { $0["volume_uuid"] as? String == U }?["modus"] as? String, "nurlesen")
        XCTAssertEqual(e.first { $0["volume_uuid"] as? String == fremd }?["max_bytes"] as? Int, 99)
        XCTAssertEqual(calls, ["eigner true 501:20"])
    }
    func testSetzenAendertModusUndEntfernen() throws {
        try liste(gut)
        try listeMitEigner().freigabeSetzen(U, modus: "schreiben", maxBytes: 0, uid: 501)
        XCTAssertEqual(try eintraege()[0]["modus"] as? String, "schreiben")
        try listeMitEigner().freigabeSetzen(U, modus: "entfernen", maxBytes: 0, uid: 501)
        XCTAssertEqual(try eintraege().count, 0)
    }
    func testSetzenKaputteListeNieUeberschreiben() throws {
        try liste("{kaputt")
        XCTAssertThrowsError(try listeMitEigner().freigabeSetzen(U, modus: "schreiben", maxBytes: 5, uid: 501))
        XCTAssertThrowsError(try listeMitEigner().freigabeSetzen(U, modus: "entfernen", maxBytes: 0, uid: 501))
        XCTAssertEqual(try String(contentsOfFile: listePfad, encoding: .utf8), "{kaputt")
    }
    func testSetzenAbgelehnt() throws {
        try liste(gut)
        let vorher = try String(contentsOfFile: listePfad, encoding: .utf8)
        XCTAssertThrowsError(try listeMitEigner().freigabeSetzen(U, modus: "root", maxBytes: 5, uid: 501))          // unbekannter Modus
        XCTAssertThrowsError(try listeMitEigner().freigabeSetzen("../x", modus: "schreiben", maxBytes: 5, uid: 501)) // ungueltige UUID
        XCTAssertThrowsError(try listeMitEigner().freigabeSetzen(fremd, modus: "schreiben", maxBytes: 0, uid: 501)) // neu ohne max_bytes
        var l = listeMitEigner(); l.knotenArt = { _ in nil }
        XCTAssertThrowsError(try l.freigabeSetzen(U, modus: "schreiben", maxBytes: 5, uid: 501))                    // Container fehlt
        XCTAssertEqual(try String(contentsOfFile: listePfad, encoding: .utf8), vorher)
        XCTAssertEqual(calls, [])
    }
}
