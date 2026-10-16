import XCTest
@testable import DroboKern

/// Sicherung zurueckspielen: ausschliesslich an Abbildern (nie ein Drobo-Geraet).
extension KernTests {
    static let uuidA = "AAAAAAAA-0000-0000-0000-000000000001"

    /// Abbild + Sicherung + Original-Kopie; liefert (Abbild, Sicherungsordner, Original-Bytes).
    func zurueckAufbau(_ name: String = "z") throws -> (String, String, Data) {
        let f = try abbild(name, journal: false, marker: false)
        let r = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: Self.uuidA, anzahl: 5)
        return (f, r.ordner, lies(f))
    }
    func forkOffset(_ ordner: String, _ fork: String) throws -> UInt64 {
        let m = try JSONSerialization.jsonObject(with: lies(ordner + "/extents.json")) as! [String: Any]
        let e = ((m["forks"] as! [String: Any])[fork] as! [String: Any])["extents"] as! [[String: Any]]
        return (e[0]["volumeOffset"] as! NSNumber).uint64Value
    }
    func beschaedigen(_ f: String, _ ordner: String) throws {
        try patch(f, try forkOffset(ordner, "catalog") + 100, [0xEE, 0xEE, 0xEE])
        try patch(f, 3000, [0xDD])                                   // Kopf-Bereich
        try patch(f, UInt64(lies(f).count) - 5000, [0xCC])           // Ende-Bereich
    }

    func testZurueckspielenStelltForksKopfUndEndeHer() throws {
        let (f, s, orig) = try zurueckAufbau()
        try beschaedigen(f, s)
        XCTAssertNotEqual(lies(f), orig)
        let p = try zurueckspielenProbe(geraet: f, sicherung: s, uuid: Self.uuidA)
        XCTAssertGreaterThan(p.gesamt, 0); XCTAssertEqual(p.zustand, .fremd)
        XCTAssertEqual(p.abweichend.first { $0.label.hasPrefix("catalog") }?.abweichend, 1)
        XCTAssertEqual(p.abweichend.first { $0.label == "kopf" }?.abweichend, 1); XCTAssertEqual(p.abweichend.first { $0.label == "ende" }?.abweichend, 1)
        XCTAssertNotEqual(lies(f), orig, "Probelauf darf nichts schreiben")
        // ohne ausdrueckliche Bestaetigung (erzwinge) kein Schreiben
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: f, sicherung: s, uuid: Self.uuidA)) { XCTAssertTrue("\($0)".contains("nicht bestaetigt"), "\($0)") }
        XCTAssertNotEqual(lies(f), orig)
        var groessen: [Int] = []
        let fehler = try zurueckspielenAusfuehren(geraet: f, sicherung: s, uuid: Self.uuidA, schreibgroesse: 524288, erzwinge: true, schreibHaken: { groessen.append($0) })
        XCTAssertEqual(fehler, []); XCTAssertEqual(lies(f), orig)
        XCTAssertFalse(groessen.isEmpty); XCTAssertLessThanOrEqual(groessen.max()!, 524288); XCTAssertTrue(groessen.contains(524288))
        // danach Probelauf: nichts weicht ab
        let q = try zurueckspielenProbe(geraet: f, sicherung: s, uuid: Self.uuidA)
        XCTAssertEqual(q.gesamt, 0); XCTAssertEqual(q.zustand, .vorher)
    }

    func testZurueckspielenSchreibgroesseGrenzen() throws {
        let (f, s, _) = try zurueckAufbau(); try beschaedigen(f, s); let kaputt = lies(f)
        for g in [524289, 524288 + 4096, 4 << 20, 0, -4096, 1000] {
            XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: f, sicherung: s, schreibgroesse: g, erzwinge: true), "\(g)") { XCTAssertTrue("\($0)".contains("Schreibgroesse"), "\($0)") }
            XCTAssertEqual(lies(f), kaputt)
        }
        var groessen: [Int] = []
        XCTAssertEqual(try zurueckspielenAusfuehren(geraet: f, sicherung: s, schreibgroesse: 4096, erzwinge: true, schreibHaken: { groessen.append($0) }), [])
        XCTAssertEqual(Set(groessen), [4096])
    }

    func testZurueckspielenFalschesGeraetWirdAbgelehnt() throws {
        let (_, s, _) = try zurueckAufbau("z1")
        // gleiche Groesse, anderes Volume (andere Kennung im Header)
        let anderes = try abbild("z2", journal: false, marker: false); let vorher = lies(anderes)
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: anderes, sicherung: s, erzwinge: true)) { XCTAssertTrue("\($0)".contains("Volume-Kennung"), "\($0)") }
        XCTAssertThrowsError(try zurueckspielenProbe(geraet: anderes, sicherung: s)) { XCTAssertTrue("\($0)".contains("Volume-Kennung"), "\($0)") }
        XCTAssertEqual(lies(anderes), vorher)
        // andere Groesse
        let gross = "\(dir)/gross.img"; XCTAssertEqual(ausfuehren("/usr/bin/truncate", ["-s", "96m", gross]).0, 0)
        try? Data(lies(anderes)).write(to: URL(fileURLWithPath: gross)); try FileHandle(forUpdating: URL(fileURLWithPath: gross)).truncate(atOffset: 96 << 20)
        let gv = lies(gross)
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: gross, sicherung: s, erzwinge: true)) { XCTAssertTrue("\($0)".contains("Volumeende"), "\($0)") }
        XCTAssertEqual(lies(gross), gv)
        // keine HFS-Signatur
        let leer = "\(dir)/leer.img"; XCTAssertEqual(ausfuehren("/usr/bin/truncate", ["-s", "64m", leer]).0, 0)
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: leer, sicherung: s, erzwinge: true)) { XCTAssertTrue("\($0)".contains("primaeren VH nicht H+/HX"), "\($0)") }
        // Sicherung eines anderen Volumes (UUID im Ordnernamen)
        XCTAssertThrowsError(try zurueckspielenProbe(geraet: anderes, sicherung: s, uuid: "BBBBBBBB-0000-0000-0000-000000000002")) { XCTAssertTrue("\($0)".contains("anderen Volume"), "\($0)") }
    }

    func testZurueckspielenEingehaengtOderAttachtWirdAbgelehnt() throws {
        let (f, s, _) = try zurueckAufbau(); try beschaedigen(f, s); let kaputt = lies(f)
        let dev = try anhaengen(f)       // Abbild ist attacht
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: f, sicherung: s, erzwinge: true)) { XCTAssertTrue("\($0)".contains("attacht"), "\($0)") }
        // Geraet mit Kernel-Mount
        let mp = "\(dir)/zm"; try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        XCTAssertEqual(ausfuehren("/sbin/mount", ["-t", "hfs", dev, mp]).0, 0, "mount"); orte.append(mp)
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: "/dev/r" + dev.dropFirst(5), sicherung: s, erzwinge: true)) { XCTAssertTrue("\($0)".contains("eingehaengt"), "\($0)") }
        XCTAssertEqual(ausfuehren("/sbin/umount", [mp]).0, 0); orte.removeAll { $0 == mp }
        ausfuehren("/usr/bin/hdiutil", ["detach", dev]); geraete.removeAll { $0 == dev }
        XCTAssertEqual(lies(f).count, kaputt.count)
    }

    func testZurueckspielenPruefsummeKaputtUndBlockgrenzen() throws {
        let (f, s, _) = try zurueckAufbau(); try beschaedigen(f, s); let kaputt = lies(f)
        // 1 Pruefsumme
        try patch(s + "/attributes.bin", 10, [0x01])
        for aufruf in [{ _ = try zurueckspielenAusfuehren(geraet: f, sicherung: s, erzwinge: true) }, { _ = try zurueckspielenProbe(geraet: f, sicherung: s) }] {
            XCTAssertThrowsError(try aufruf()) { XCTAssertTrue("\($0)".contains("SHA256SUMS"), "\($0)") }
        }
        XCTAssertEqual(lies(f), kaputt)
        // 2 Blockgrenze: volumeOffset +1 in extents.json (Pruefsumme angepasst, sonst greift schon 1)
        let (f2, s2, _) = try zurueckAufbau("z3"); try beschaedigen(f2, s2); let k2 = lies(f2)
        var j = String(decoding: lies(s2 + "/extents.json"), as: UTF8.self)
        let off = try forkOffset(s2, "catalog"); XCTAssertTrue(j.contains("\(off)"))
        j = j.replacingOccurrences(of: "\"volumeOffset\" : \(off)", with: "\"volumeOffset\" : \(off + 1)")
        try Data(j.utf8).write(to: URL(fileURLWithPath: s2 + "/extents.json"))
        let sums = String(decoding: lies(s2 + "/SHA256SUMS"), as: UTF8.self).split(separator: "\n").map { z -> String in
            let t = z.components(separatedBy: "  "); return t[1] == "extents.json" ? "\(try! sha256Datei(s2 + "/extents.json"))  extents.json" : String(z) }.joined(separator: "\n") + "\n"
        try Data(sums.utf8).write(to: URL(fileURLWithPath: s2 + "/SHA256SUMS"))
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: f2, sicherung: s2, erzwinge: true)) { XCTAssertTrue("\($0)".contains("ausgerichtet"), "\($0)") }
        XCTAssertEqual(lies(f2), k2)
    }

    func testZurueckspielenProbeLiestNurUndSchreibenBrauchtSchreibrecht() throws {
        let (f, s, _) = try zurueckAufbau(); try beschaedigen(f, s); let kaputt = lies(f)
        XCTAssertEqual(chmod(f, 0o444), 0)
        XCTAssertNoThrow(try zurueckspielenProbe(geraet: f, sicherung: s))
        XCTAssertThrowsError(try zurueckspielenAusfuehren(geraet: f, sicherung: s, erzwinge: true))
        XCTAssertEqual(lies(f), kaputt); chmod(f, 0o644)
    }

    /// Ganzer Weg ueber Kern am attachten Abbild (Geraeteknoten /dev/rdiskN): Probe, Ausfuehren, Nachpruefung, Eingehaengt-Sperre.
    func testKernZurueckspielenAmGeraet() throws {
        let f = try abbild("k", journal: false, marker: false)
        let dev = try anhaengen(f); let u = try uuid(dev)
        ausfuehren("/usr/bin/hdiutil", ["detach", dev]); geraete.removeAll { $0 == dev }
        _ = try metadatenSichern(quelle: f, ort: sicherOrt, uuid: u, anzahl: 5)
        let orig = lies(f)
        let s0 = try XCTUnwrap(eigeneSicherungen(ort: sicherOrt, uuid: u).first)
        try beschaedigen(f, sicherOrt + "/" + s0)
        let dev2 = try anhaengen(f); XCTAssertEqual(try uuid(dev2), u)
        var k = kern(u, try freigabe([eintrag(u, "nurlesen")])); k.helfer = { _, _ in nil }
        XCTAssertEqual(k.sicherungen(), [s0])
        XCTAssertThrowsError(try k.zurueckspielenProbe(sicherung: "../etc")) { XCTAssertTrue("\($0)".contains("Unbekannte Sicherung")) }
        let p = try k.zurueckspielenProbe(sicherung: s0); XCTAssertGreaterThan(p.gesamt, 0)
        let r = try k.zurueckspielen(sicherung: s0)
        XCTAssertEqual(r.ok, true, "\(r.probleme)")
        ausfuehren("/usr/bin/hdiutil", ["detach", dev2]); geraete.removeAll { $0 == dev2 }
        XCTAssertEqual(lies(f), orig)
        XCTAssertTrue(k.ablage.protokollLesen().contains { $0.text.contains("Zurueckgespielt") })
        // eingehaengt -> Kern lehnt ab
        let dev3 = try anhaengen(f); let mp = "\(dir)/km"; try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        XCTAssertEqual(ausfuehren("/sbin/mount", ["-t", "hfs", dev3, mp]).0, 0); orte.append(mp)
        XCTAssertThrowsError(try k.zurueckspielen(sicherung: s0)) { XCTAssertTrue("\($0)".contains("Zuerst aushaengen"), "\($0)") }
    }
}
