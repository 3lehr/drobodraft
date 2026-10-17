import XCTest
@testable import DroboKern

/// M: Netz-Drobo = Ziel (IQN, sonst Adresse), nicht Volume-UUID. N: Ordnername = HFS-Volumename. Werte aus der echten einstellungen.json des Betreibers (2026-10-17), UUIDs gekuerzt.
final class NetzIdentitaetTests: XCTestCase {
    let iqn = "iqn.2005-06.com.datarobotics:drobopro.tdb103040230.node0"
    func eintrag(_ uuid: String, lun: Int, _ luns: [(Int, String, String)], iqn: String? = "x", host: String = "192.168.178.90") -> DroboEintrag {
        DroboEintrag(uuid: uuid, name: "DroboPro", netz: NetzZiel(host: host, lun: lun, iqn: iqn == "x" ? self.iqn : iqn, luns: luns.map { NetzLunEintrag(lun: $0.0, uuid: $0.1, name: $0.2) }))
    }
    /// Zwei Eintraege desselben Geraets: genau eine Drobo, Name/Rolle/UUID des aelteren, LUNs vereinigt, Namen ohne Standardnamen.
    func testZweiEintraegeSelbesZielWerdenEins() {
        var e = Einstellungen()
        e.drobos = [DroboEintrag(uuid: "C2E3", name: "Drobo 5C"),
                    eintrag("1036", lun: 1, [(0, "42FC", "drobo pro 2"), (1, "1036", "Volume 2")]),
                    eintrag("42FC", lun: 0, [(0, "42FC", "Volume 1"), (1, "1036", "Volume 2")])]
        let m = e.netzZusammengefuehrt()
        XCTAssertEqual(m.drobos.map(\.uuid), ["C2E3", "1036"], "5C unberuehrt, DroboPro nur einmal, UUID des aelteren")
        let n = m.drobos[1].netz!
        XCTAssertEqual(n.lun, 1); XCTAssertEqual(n.luns?.map(\.lun), [0, 1]); XCTAssertEqual(n.luns?.map(\.name), ["drobo pro 2", "Volume 2"], "Standardname weicht dem Nutzer-/HFS-Namen")
        XCTAssertEqual(m.netzZusammengefuehrt(), m, "idempotent")
    }
    func testNeuesteUUIDJeLUNUndAdresswechselUeberIQN() {
        var e = Einstellungen()
        e.drobos = [eintrag("A", lun: 1, [(1, "ALT", "Volume 2")], host: "192.168.178.90"), eintrag("B", lun: 1, [(1, "NEU", "DATEN")], host: "192.168.178.91")]   // gleiche IQN, andere Adresse
        let n = e.netzZusammengefuehrt().drobos
        XCTAssertEqual(n.count, 1); XCTAssertEqual(n[0].netz?.luns?.first?.uuid, "NEU"); XCTAssertEqual(n[0].netz?.luns?.first?.name, "DATEN")
        e.drobos = [eintrag("A", lun: 1, [], iqn: nil), eintrag("B", lun: 0, [], iqn: "fremd", host: "192.168.178.91"), eintrag("C", lun: 0, [], iqn: nil, host: "192.168.178.92")]
        XCTAssertEqual(e.netzZusammengefuehrt().drobos.count, 3, "andere Adresse und andere/keine IQN = andere Drobos")
    }
    func testGeladeneEinstellungenSindZusammengefuehrt() throws {
        let dir = NSTemporaryDirectory() + "ident-\(UUID().uuidString)"; defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = Datenablage(ordner: dir)
        var e = Einstellungen(); e.drobos = [eintrag("1036", lun: 1, [(1, "1036", "Volume 2")]), eintrag("42FC", lun: 0, [(0, "42FC", "Volume 1")])]
        a.einstellungenSetzen(e)
        XCTAssertEqual(a.einstellungen().drobos.count, 1); XCTAssertEqual(a.einstellungen().drobos[0].netz?.luns?.count, 2)
    }
    func testOrdnerNameHFSVorGespeichertVorStandard() {
        XCTAssertEqual(iscsiOrdnerName(hfs: "DROPRO1", gespeichert: "Volume 2", lun: 1), "DROPRO1", "Finder-Name gewinnt (Befund N: Ordner hiess 'Volume 1')")
        XCTAssertEqual(iscsiOrdnerName(hfs: nil, gespeichert: "ARCHIV", lun: 0), "ARCHIV"); XCTAssertEqual(iscsiOrdnerName(hfs: "", gespeichert: nil, lun: 1), "Volume 2")
    }
    func testGespeicherteLunNamenWerdenBeimEinlesenAktualisiert() {
        let nz = NetzZiel(host: "h", lun: 1, luns: [NetzLunEintrag(lun: 0, uuid: "U0", name: "Volume 1"), NetzLunEintrag(lun: 1, uuid: "U1", name: "Volume 2"), NetzLunEintrag(lun: 5, uuid: "U5", name: "Rest")])
        let g = [LunEintrag(lun: 0, groesse: 1, schema: "GPT", partitionBytes: 1, uuid: "U0N", volumeName: "drobo pro 2"), LunEintrag(lun: 1, groesse: 1, schema: "GPT", partitionBytes: 1, uuid: "U1", volumeName: nil),
                 LunEintrag(lun: 2, groesse: 1, schema: "-", partitionBytes: nil, uuid: nil)]
        let r = netzLunsAbgleichen(nz, gelesen: g, standardName: { "Volume \($0 + 1)" }).luns!
        XCTAssertEqual(r.map(\.name), ["drobo pro 2", "Volume 2", "Rest"], "gelesener HFS-Name gewinnt, unlesbar behaelt den gespeicherten, ungelesene LUN bleibt"); XCTAssertEqual(r[0].uuid, "U0N")
        XCTAssertEqual(r.map(\.lun), [0, 1, 5], "LUN ohne Dateisystem wird nicht aufgenommen")
    }
    /// R: gespeicherter Stand der LUNs (Groesse, Partition) ueberlebt Speichern/Laden, alte Dateien ohne diese Felder bleiben lesbar.
    func testGespeicherterLunStand() throws {
        let nz = NetzZiel(host: "h", lun: 1, luns: [NetzLunEintrag(lun: 1, uuid: "U1", name: "Volume 2")])
        let g = [LunEintrag(lun: 1, groesse: 16 << 40, schema: "GPT", partitionBytes: 2 << 40, uuid: "U1", volumeName: "DROPRO1")]
        let n = netzLunsAbgleichen(nz, gelesen: g, standardName: { "Volume \($0 + 1)" })
        let rt = try JSONDecoder().decode(NetzZiel.self, from: JSONEncoder().encode(n))
        let l = try XCTUnwrap(rt.luns?.first?.alsLunEintrag)
        XCTAssertEqual(l.groesse, 16 << 40); XCTAssertEqual(l.partitionBytes, 2 << 40); XCTAssertTrue(l.hatDateisystem); XCTAssertEqual(l.volumeName, "DROPRO1")
        let alt = #"{"host":"h","lun":1,"luns":[{"lun":1,"uuid":"U1","name":"X"}]}"#
        XCTAssertNil(try JSONDecoder().decode(NetzZiel.self, from: Data(alt.utf8)).luns?.first?.groesse, "alte Datei ohne Stand")
    }
}
