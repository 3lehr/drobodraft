import XCTest
@testable import DroboKern

/// Weiterleitung des Hilfsdienstes (ISCSIWeiterleitung) und iSCSI-Freigabe: ohne Root, Ziel ist das Python-Pruefziel auf 127.0.0.1:3260
/// (nur mit der Test-Ausnahme fuer Loopback; der Dienst-Init lehnt 127.0.0.1 ab).
final class WeiterleitungTests: XCTestCase {
    let dienst = ISCSIWeiterleitung()

    func testZielGrenzwerte() {
        let ok = ["10.0.0.1", "172.16.0.0", "172.31.255.255", "192.168.178.90", "169.254.1.1", "10.255.255.255"]
        let nein = ["172.15.255.255", "172.32.0.0", "127.0.0.1", "192.167.1.1", "192.169.0.1", "169.253.1.1", "169.255.0.1", "11.0.0.1", "8.8.8.8", "9.255.255.255",
                    "0.0.0.0", "192.168.1", "192.168.1.1.1", "192.168.001.001", "010.0.0.1", "fe80::1", "example.local", "192.168.1.256", " 10.0.0.1", ""]
        for h in ok { XCTAssertNil(dienst.zielPruefen(host: h, port: 3260), h) }
        for h in nein { XCTAssertNotNil(dienst.zielPruefen(host: h, port: 3260), h) }
        for p: UInt16 in [3259, 3261, 0, 80, 22, 65535] { XCTAssertNotNil(dienst.zielPruefen(host: "192.168.1.1", port: p), "port \(p)") }
        XCTAssertNil(ISCSIWeiterleitung(testLoopbackErlaubt: true).zielPruefen(host: "127.0.0.1", port: 3260))
        XCTAssertNotNil(ISCSIWeiterleitung(testLoopbackErlaubt: true).zielPruefen(host: "127.0.0.2", port: 3260))
        XCTAssertThrowsError(try dienst.port(host: "127.0.0.1", port: 3260), "Dienst-Init lehnt Loopback ab")
    }

    func testWeiterleitungByteGleichUndLeerlaufBlockiert() throws {
        guard let base = Kern.umgebung("DROBO_TESTDIR") else { throw XCTSkip("DROBO_TESTDIR nicht gesetzt") }
        let dir = "\(base)/relay-\(UUID().uuidString)"; try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for i in 0..<2 { FileManager.default.createFile(atPath: "\(dir)/l\(i).img", contents: nil); truncate("\(dir)/l\(i).img", 4 << 20) }
        let skript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("iscsi_ziel.py").path
        let p = Process(); let aus = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", skript, "--image", "\(dir)/l0.img", "--image", "\(dir)/l1.img", "--log", "\(dir)/log", "--port", "3260"]
        p.standardOutput = aus; try p.run(); defer { p.terminate(); p.waitUntilExit() }
        var z = Data(); while !z.contains(10) { let d = aus.fileHandleForReading.availableData; if d.isEmpty { return XCTFail("Ziel startete nicht (Port 3260 belegt?)") }; z += d }
        let relay = ISCSIWeiterleitung(testLoopbackErlaubt: true)
        let lokal = try relay.port(host: "127.0.0.1", port: 3260)
        XCTAssertNotEqual(lokal, 3260); XCTAssertEqual(try relay.port(host: "127.0.0.1", port: 3260), lokal, "wiederverwendet")
        let d = try ISCSISitzung(host: "127.0.0.1", port: lokal); let ziele = try d.ziele(); d.abmelden()
        let s = try ISCSISitzung(host: "127.0.0.1", port: lokal, ziel: ziele[0].name)
        let muster = (0..<524288).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ ($0 >> 9)) }
        try s.schreiben(lun: 1, lba: 8, daten: muster)
        XCTAssertEqual(try s.lesen(lun: 1, lba: 8, bloecke: 1024), muster, "ueber die Weiterleitung byte-gleich")
        XCTAssertEqual([UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/l1.img"))[4096..<4096 + 524288]), muster, "und am Abbild")
        XCTAssertEqual(relay.offen, 1)
        let alt = Date(timeIntervalSinceNow: -100)
        XCTAssertFalse(relay.beendenErlaubt(aktiv: 0, letzte: alt), "offene Verbindung blockiert das Leerlauf-Ende")
        XCTAssertFalse(relay.beendenErlaubt(aktiv: 1, letzte: alt))
        s.abmelden()
        for _ in 0..<40 where relay.offen != 0 { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertEqual(relay.offen, 0)
        XCTAssertTrue(relay.beendenErlaubt(aktiv: 0, letzte: alt))
        XCTAssertFalse(relay.beendenErlaubt(aktiv: 0, letzte: Date()), "erst nach 30 s Ruhe")
    }

    func testISCSIFreigabeLandetImContainerDesISCSIModulsMitMaxBytes() throws {
        let home = NSTemporaryDirectory() + "helfer-\(UUID().uuidString)"; defer { try? FileManager.default.removeItem(atPath: home) }
        for m in [modulKennung, appKennung + ".iscsi"] { try FileManager.default.createDirectory(atPath: "\(home)/Library/Containers/\(m)/Data", withIntermediateDirectories: true) }
        var l = HelferLogik(); l.ordnerVon = { _ in home }; l.datei = { _ in nil }; l.eigner = { _, _, _ in 0 }
        let u = "11111111-2222-3333-4444-555555555555"
        XCTAssertThrowsError(try l.freigabeSetzen(u, modus: "nurlesen", maxBytes: 0, uid: 501, modul: ".iscsi"), "max_bytes Pflicht")
        try l.freigabeSetzen(u, modus: "schreiben", maxBytes: 2_199_023_255_552, uid: 501, modul: ".iscsi")
        let p = "\(home)/Library/Containers/\(appKennung).iscsi/Data/freigabe.json"
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as! [[String: Any]]
        XCTAssertEqual(j.first?["modus"] as? String, "schreiben"); XCTAssertEqual((j.first?["max_bytes"] as? NSNumber)?.uint64Value, 2_199_023_255_552)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(home)/Library/Containers/\(modulKennung)/Data/freigabe.json"), "Block-Modul-Liste unberuehrt")
        try l.freigabeSetzen(u, modus: "entfernen", maxBytes: 0, uid: 501, modul: ".iscsi")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p))) as! [Any]).count, 0)
    }
}
