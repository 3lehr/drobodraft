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
        let a = anforderung(prefix: "org.example.x", team: "ABCDE12345")
        XCTAssertEqual(SecRequirementCreateWithString(a as CFString, [], &req), errSecSuccess)
        XCTAssertTrue(a.contains("ABCDE12345") && a.contains("\"org.example.x.drobofsprobe\"") && a.contains("\"org.example.x.drobo\"") && !a.contains("anchor trusted"))
        XCTAssertFalse(a.contains("de.begod"), "kein fest eingebauter Praefix")
        // die zur Laufzeit gebildete Anforderung ist ebenfalls gueltig (Team aus der eigenen Signatur, im Test ggf. leer)
        XCTAssertEqual(SecRequirementCreateWithString(helferAnforderung as CFString, [], &req), errSecSuccess)
    }
    func testPraefixKommtAusUmgebungOderBundleNichtAusDemCode() {
        XCTAssertTrue(helferDienst.hasSuffix(".drobohelper") && appKennung.hasSuffix(".drobofsprobe") && modulKennung.hasSuffix(".drobofsprobe.fsmodule"))
        XCTAssertEqual(appKennung, Identitaet.prefix + ".drobofsprobe"); XCTAssertEqual(cliKennung, Identitaet.prefix + ".drobo")
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

/// Einhaengeordner /Volumes/<Name> ueber den Dienst: Attrappen fuer mkdir/rmdir/stat, Basis in einem Temp-Ordner.
extension HelferTests {
    func ordnerLogik(name: String = "Drobo", bsd: String? = "disk9s2") -> (HelferLogik, [String]) {
        var l = logik(bsd: bsd)
        l.finden = { u in bsd.map { Medium(bsd: $0, uuid: u.uppercased(), groesse: 1, name: name) } }
        l.volumesBasis = home + "/Volumes"
        l.chown = { p, u, g in self.calls.append("chown \(p) \(u):\(g)"); return 0 }
        return (l, [])
    }
    func testOrdnerAnlegenNurVolumenameUndChownAnAufrufer() throws {
        try liste(gut); try FileManager.default.createDirectory(atPath: home + "/Volumes", withIntermediateDirectories: true)
        let (l, _) = ordnerLogik()
        let me = getuid()
        let p = try l.ordnerAnlegen(U, uid: me)
        XCTAssertEqual(p, home + "/Volumes/Drobo"); XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertEqual(calls, ["chown \(p) \(me):20"])
        // leerer eigener Ordner wird wiederverwendet; Ordner eines anderen Nutzers nie
        XCTAssertEqual(try l.ordnerAnlegen(U, uid: me), p)
        XCTAssertThrowsError(try l.ordnerAnlegen(U, uid: me + 1))
        XCTAssertThrowsError(try l.ordnerEntfernen(U, uid: me + 1)); XCTAssertTrue(FileManager.default.fileExists(atPath: p))
        XCTAssertNoThrow(try l.ordnerEntfernen(U, uid: me)); XCTAssertFalse(FileManager.default.fileExists(atPath: p))
        XCTAssertNoThrow(try l.ordnerEntfernen(U, uid: me), "nicht vorhanden = ok")
    }
    func testOrdnerUngueltigeNamenUndFremdeUUIDAbgelehnt() throws {
        try liste(gut); try FileManager.default.createDirectory(atPath: home + "/Volumes", withIntermediateDirectories: true)
        for n in ["", ".versteckt", "a/b", "..", "x\u{01}y", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try ordnerLogik(name: n).0.ordnerAnlegen(U, uid: 501), n) { XCTAssertTrue("\($0)".contains("nicht verwendbar"), "\($0)") }
        }
        XCTAssertThrowsError(try ordnerLogik().0.ordnerAnlegen("22222222-2222-2222-2222-222222222222", uid: 501)) { XCTAssertTrue("\($0)".contains("nicht in der Freigabeliste")) }
        XCTAssertThrowsError(try ordnerLogik(bsd: nil).0.ordnerAnlegen(U, uid: 501))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home + "/Volumes"), [])
    }
    func testOrdnerEntfernenNieNichtleerNieEinhaengepunkt() throws {
        try liste(gut); try FileManager.default.createDirectory(atPath: home + "/Volumes/Drobo", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home + "/Volumes/Drobo/datei", contents: Data())
        let (l, _) = ordnerLogik()
        XCTAssertThrowsError(try l.ordnerEntfernen(U, uid: getuid())); XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Volumes/Drobo/datei"))
        // Einhaengepunkt (st_dev weicht von /Volumes ab) wird nie entfernt
        var m = l; try FileManager.default.removeItem(atPath: home + "/Volumes/Drobo/datei")
        m.lstatDatei = { var s = stat(); guard lstat($0, &s) == 0 else { return nil }; if $0.hasSuffix("/Drobo") { s.st_dev += 1 }; return s }
        XCTAssertThrowsError(try m.ordnerEntfernen(U, uid: getuid())) { XCTAssertTrue("\($0)".contains("Einhaengepunkt")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/Volumes/Drobo"))
    }
}

extension HelferTests {
    func testZugriffPruefenWirkungslosAmBisherigenEigentuemer() throws {
        try liste(gut)
        var l = logik()
        l.datei = { _ in (501, 5) }
        l.eigner = { p, u, g in self.calls.append("chown \(p) \(u):\(g)"); return 0 }
        try l.zugriffPruefen(U, uid: 501)
        XCTAssertEqual(calls, ["chown /dev/disk9s2 501:5", "chown /dev/rdisk9s2 501:5"], "nur identischer Eigentuemer, nie ein anderer")
        // chown verweigert (Festplattenvollzugriff fehlt) -> Fehler
        l.eigner = { _, _, _ in errno = EPERM; return -1 }
        XCTAssertThrowsError(try l.zugriffPruefen(U, uid: 501)) { XCTAssertTrue("\($0)".contains("chown"), "\($0)") }
        // fremde UUID / kein Knoten: abgelehnt, ohne chown
        calls = []; l.eigner = { p, u, g in self.calls.append("chown"); return 0 }
        XCTAssertThrowsError(try l.zugriffPruefen("22222222-2222-2222-2222-222222222222", uid: 501))
        XCTAssertThrowsError(try logik(bsd: nil).zugriffPruefen(U, uid: 501))
        l.datei = { _ in nil }; XCTAssertThrowsError(try l.zugriffPruefen(U, uid: 501)); XCTAssertEqual(calls, [])
    }
}
