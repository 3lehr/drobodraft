import XCTest
@testable import DroboKern

/// Tempotest: Messzyklus, Schutzregeln (Rot-Proben), Formattabelle. Nur Testordner/Abbilder, nie die Drobo.
extension KernTests {
    var testOrdnerSpeed: String { let q = "\(dir)/tempo"; try? FileManager.default.createDirectory(atPath: q, withIntermediateDirectories: true); return q }
    func sicherungMitMarker() throws -> String {
        let s = "\(dir)/sich_ok"; try FileManager.default.createDirectory(atPath: s, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: s + "/" + markerName)); return s
    }

    func testTempoLesenMitZiel() throws {
        let q = testOrdnerSpeed
        XCTAssertThrowsError(try tempoLesen(ort: q, uuid: "U")) { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }   // keine grosse Datei
        try Data(repeating: 1, count: 20 << 20).write(to: URL(fileURLWithPath: q + "/gross.bin"))
        let a = Datenablage(ordner: "\(dir)/tempoA")
        var fort: [TempoFortschritt] = []
        let m = try tempoLesen(ort: q, uuid: "U", zielBytes: 10 << 20, ablage: a, fortschritt: { fort.append($0) })
        XCTAssertEqual(m.dateien, 1); XCTAssertEqual(m.bytes, 10 << 20, "Ziel begrenzt die gelesene Menge"); XCTAssertGreaterThan(m.mbProSekunde, 1)
        XCTAssertEqual(a.tempoVerlauf().count, 1)
        XCTAssertEqual(fort.last?.bytes, 10 << 20); XCTAssertEqual(fort.last?.von, 10 << 20); XCTAssertEqual(fort.first?.art, "lesen")
        // Abbruch
        XCTAssertThrowsError(try tempoLesen(ort: q, uuid: "U", abbrechen: { true }))
    }

    func testZyklusSchreibenLesenRäumtAuf() throws {
        let q = testOrdnerSpeed; let a = Datenablage(ordner: "\(dir)/tempoB")
        var phasen = Set<String>(); var letzte: TempoFortschritt?
        let z = try tempoSchreibenUndLesen(ort: q, uuid: "U", groesse: 20_000_000, ablage: a, fortschritt: { phasen.insert($0.art); letzte = $0 })
        XCTAssertEqual(z.schreiben?.bytes, 20_000_000); XCTAssertEqual(z.lesen?.bytes, 20_000_000)
        XCTAssertEqual(phasen, ["schreiben", "lesen"]); XCTAssertEqual(letzte?.bytes, 20_000_000)
        XCTAssertEqual(a.tempoVerlauf().map { $0.art }, ["schreiben", "lesen"], "beide Phasen im Verlauf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: q + "/" + tempoTestordner), "Testdatei/-ordner wieder geloescht")
    }

    func testAbbruchWaehrendSchreibenLoeschtTestdatei() throws {
        let q = testOrdnerSpeed; var n = 0
        let z = try tempoSchreibenUndLesen(ort: q, uuid: "U", groesse: 100_000_000, abbrechen: { n += 1; return n > 2 })
        XCTAssertNil(z.schreiben); XCTAssertNil(z.lesen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: q + "/" + tempoTestordner))
    }

    // Rot-Proben der Schutzregeln
    func testSchreibenVerweigertBeiNurLesenOhneSicherungOhneRw() throws {
        let ok = try sicherungMitMarker()
        XCTAssertNoThrow(try tempoSchreibenErlaubt(nurlesen: false, rwAktiv: true, sicherung: ok))
        for (ro, rw, s) in [(true, true, ok), (false, false, ok), (false, true, nil), (false, true, "\(dir)/gibt_es_nicht"), (false, true, dir)] as [(Bool, Bool, String?)] {
            XCTAssertThrowsError(try tempoSchreibenErlaubt(nurlesen: ro, rwAktiv: rw, sicherung: s), "ro=\(ro) rw=\(rw) s=\(s ?? "nil")") { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }
        }
    }

    func testSchreibenVerweigertBeiZuWenigPlatz() throws {
        let q = testOrdnerSpeed
        var s = statfs(); XCTAssertEqual(statfs(q, &s), 0)
        let frei = UInt64(s.f_bavail) * UInt64(s.f_bsize)
        // Grenze: frei/2 + 1 passt nicht (x2 Reserve), frei kommt nie an
        XCTAssertThrowsError(try tempoPlatzPruefen(ort: q, groesse: frei / 2 + 1_000_000_000)) { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }
        XCTAssertNoThrow(try tempoPlatzPruefen(ort: q, groesse: 1_000_000))
        XCTAssertThrowsError(try tempoSchreibenUndLesen(ort: q, uuid: "U", groesse: frei * 4))   // nie echt schreiben: auch ohne Reserve passt das nicht
        XCTAssertFalse(FileManager.default.fileExists(atPath: q + "/" + tempoTestordner), "bei zu wenig Platz wird nichts angelegt")
    }

    /// Ganze Kern-Kette: Kernel-Mount nur lesend -> tempoLauf(schreiben: true) verweigert, nichts angelegt.
    func testKernTempoLaufSchreibenBeiRoVerweigert() throws {
        let f = try abbild("tempo_ro", journal: false, marker: false)
        let dev = try anhaengen(f); let u = try uuid(dev)
        let mp = "\(dir)/tempo_mp"; try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
        XCTAssertEqual(ausfuehren("/sbin/mount", ["-t", "hfs", "-r", dev, mp]).0, 0); orte.append(mp)
        let k = kern(u, try freigabe([eintrag(u, "nurlesen")]))
        XCTAssertThrowsError(try k.tempoLauf(schreiben: true, groesse: 1_000_000)) { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mp + "/" + tempoTestordner))
        // Lesen ohne grosse Datei: sauberer Fehler statt Absturz
        XCTAssertThrowsError(try k.tempoLauf(schreiben: false, groesse: 1_000_000)) { XCTAssertEqual(($0 as? AppFehler)?.code, 36) }
    }
}

/// Formattabelle: Ableitung und Abschreibkontrolle gegen die Quelle.
final class FormateTests: XCTestCase {
    func testMaxBilderAbleitung() {
        // ProRes 422 HQ 1920x1080 30p = 220 Mb/s = 27,5 MB/s -> 0,91667 MB je Bild
        let hd = proResTabelle[0]; let hq = 3
        XCTAssertEqual(hd.mbit(codec: hq, fps: 30), 220)
        XCTAssertEqual(hd.mbProBild(codec: hq, fps: 30)!, 220.0 / 8 / 30, accuracy: 1e-9)
        XCTAssertEqual(maxBilderBerechnen(mbProSekunde: 100, mbProBild: 0.9), 111.111, accuracy: 0.001)
        XCTAssertEqual(hd.maxBilder(mbProSekunde: 27.5, codec: hq, fps: 30)!, 30, accuracy: 1e-9, "Rate = Tabellenwert -> genau Bildrate")
        XCTAssertEqual(hd.maxBilder(mbProSekunde: 55, codec: hq, fps: 30)!, 60, accuracy: 1e-9)
        XCTAssertEqual(maxBilderBerechnen(mbProSekunde: 50, mbProBild: 0), 0, "Division durch 0 abgefangen")
    }
    func testReichtGrenzwert() {
        let uhd = proResTabelle[2]   // 3840x2160, ProRes 422 HQ 30p = 884 Mb/s = 110,5 MB/s
        XCTAssertEqual(uhd.reicht(mbProSekunde: 110.5, codec: 3, fps: 30), true)       // Schwelle
        XCTAssertEqual(uhd.reicht(mbProSekunde: 110.4, codec: 3, fps: 30), false)      // Schwelle - ein Hauch
        XCTAssertEqual(uhd.reicht(mbProSekunde: 120, codec: 3, fps: 30), true)
        XCTAssertEqual(uhd.reicht(mbProSekunde: 120, codec: 3, fps: 60), false)        // 60p = 1768 Mb/s = 221 MB/s
        XCTAssertNil(uhd.reicht(mbProSekunde: 120, codec: 3, fps: 29))                 // Bildrate nicht in der Quelle
        XCTAssertNil(uhd.reicht(mbProSekunde: 120, codec: 99, fps: 30))
    }
    /// Abschreibfehler fallen auf: MB je Bild muss ueber alle Bildraten gleich sein (Rundung der Quelle < 3 %), Rate steigt mit Codec und Aufloesung.
    func testTabelleInnerKonsistent() {
        for a in proResTabelle {
            XCTAssertEqual(Set(a.raten.keys), Set(proResBildraten), a.name)
            for c in 0..<proResCodecs.count {
                let b = proResBildraten.map { a.mbProBild(codec: c, fps: $0)! }
                XCTAssertLessThan((b.max()! - b.min()!) / b.max()!, 0.03, "\(a.name) \(proResCodecs[c]): \(b)")
                if c > 0 { for f in proResBildraten { XCTAssertGreaterThan(a.mbit(codec: c, fps: f)!, a.mbit(codec: c - 1, fps: f)!, "\(a.name) \(f)p") } }
            }
        }
        for (x, y) in zip(proResTabelle, proResTabelle.dropFirst()) { XCTAssertGreaterThan(y.mbit(codec: 0, fps: 60)!, x.mbit(codec: 0, fps: 60)!) }
    }
    /// Stichproben wörtlich aus der Quelle (Seite 19-21): 1080p 60p HQ 440; UHD 24p XQ 1591; 4K 30p 422 629; 8K 60p XQ 16970.
    func testStichprobenWieQuelle() {
        XCTAssertEqual(proResTabelle[0].mbit(codec: 3, fps: 60), 440)
        XCTAssertEqual(proResTabelle[2].mbit(codec: 5, fps: 24), 1591)
        XCTAssertEqual(proResTabelle[3].mbit(codec: 2, fps: 30), 629)
        XCTAssertEqual(proResTabelle[6].mbit(codec: 5, fps: 60), 16970)
    }
}
