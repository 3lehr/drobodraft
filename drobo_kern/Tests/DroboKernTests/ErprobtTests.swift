import XCTest
@testable import DroboKern

final class ErprobtTests: XCTestCase {
    func nicht(_ e: ErprobtErgebnis) -> Bool { !e.istErprobt }
    func e(_ m: String, _ b: Int?, _ a: Anschluss, _ x: ErprobtAktion) -> ErprobtErgebnis { erprobt(modell: m, build: b, anschluss: a, aktion: x) }

    func test5CSchreibenErprobt_FormatierenNicht() {
        XCTAssertTrue(e("5C Gen3", 50532, .usb, .schreiben).istErprobt)
        XCTAssertTrue(nicht(e("5C Gen3", 50532, .usb, .formatieren)), "5C: Formatieren nie gemessen")
    }
    func testProUeberWLAN_SchreibenUndFormatierenErprobt() {
        XCTAssertTrue(e("Pro", 22137, .iscsiWLAN, .schreiben).istErprobt)
        XCTAssertTrue(e("DroboPro", 22137, .iscsiWLAN, .formatieren).istErprobt)
    }
    func testProUeberKabel_SchreibenErprobt_FormatierenNicht() {
        // gemessen 2026-10-17: Modul 50 MiB ueber en8, md5 nach Neueinhaengen gleich; Formatieren ueber Kabel nie
        XCTAssertTrue(e("Pro", 22137, .iscsiKabel, .schreiben).istErprobt)
        XCTAssertTrue(nicht(e("Pro", 22137, .iscsiKabel, .formatieren)))
    }
    func testProUSBFirewireUnbekannt_NieErprobt() {
        for a in [Anschluss.usb, .firewire, .iscsiUnbekannt] { XCTAssertTrue(nicht(e("Pro", 22137, a, .schreiben)), "\(a)") }
    }
    func testBuildGrenze_MinusEins_PlusEins_Unbekannt() {
        for b in [22136, 22138] { XCTAssertTrue(nicht(e("Pro", b, .iscsiWLAN, .schreiben)), "\(b)") }
        XCTAssertTrue(nicht(e("Pro", nil, .iscsiWLAN, .schreiben)), "Firmware unbekannt")
    }
    func testFremdesModellUndKreuzung() {
        XCTAssertTrue(nicht(e("5D", 50532, .usb, .schreiben)))
        XCTAssertTrue(nicht(e("Pro", 50532, .iscsiWLAN, .schreiben)), "Build der 5C an der Pro")
        XCTAssertTrue(nicht(e("5C Gen3", 50532, .iscsiWLAN, .schreiben)), "Anschluss der Pro an der 5C")
    }
    func testNichtErprobtNenntErprobteKombinationen() {
        guard case .nichtErprobt(let l, _, _, _) = e("X", 1, .usb, .formatieren) else { return XCTFail() }
        XCTAssertEqual(l.map(\.anzeige), ["DroboPro"])
        guard case .nichtErprobt(let s, _, _, _) = e("X", 1, .usb, .schreiben) else { return XCTFail() }
        XCTAssertEqual(s.map(\.anschluss), [.usb, .iscsiWLAN, .iscsiKabel], "Kabel seit 2026-10-17 zum Schreiben erprobt")
    }

    // Teiltreffer: je Merkmal uebereinstimmend / abweichend
    func teil(_ m: String, _ b: Int?, _ a: Anschluss, _ x: ErprobtAktion = .schreiben) -> (ok: Set<Merkmal>, ab: Set<Merkmal>, bester: String?)? {
        guard case .nichtErprobt(_, let n, let ok, let ab) = e(m, b, a, x) else { return nil }
        return (ok, ab, n?.anzeige)
    }
    func testVollerTreffer_NennteintragMitAllenMerkmalen() {
        guard case .erprobt(let eintrag) = e("Pro", 22137, .iscsiWLAN, .schreiben) else { return XCTFail() }
        XCTAssertEqual(eintrag.anzeige, "DroboPro"); XCTAssertEqual(eintrag.firmwareBuild, 22137)
    }
    func testTeiltreffer_NurAnschlussAbweichend_FormatierenUeberKabel() {
        let t = teil("Pro", 22137, .iscsiKabel, .formatieren)
        XCTAssertEqual(t?.ok, [.modell, .firmware]); XCTAssertEqual(t?.ab, [.anschluss]); XCTAssertEqual(t?.bester, "DroboPro")
    }
    func testTeiltreffer_NurFirmwareAbweichend() {
        let t = teil("5C Gen3", 50533, .usb)
        XCTAssertEqual(t?.ok, [.modell, .anschluss]); XCTAssertEqual(t?.ab, [.firmware])
    }
    func testFirmwareUnbekannt_zaehltAlsAbweichend() {
        let t = teil("Pro", nil, .iscsiWLAN)
        XCTAssertEqual(t?.ab, [.firmware]); XCTAssertEqual(t?.ok, [.modell, .anschluss])
    }
    func testNurModellErprobt_FirmwareUndAnschlussAbweichend() {
        let t = teil("Pro", 1, .usb)
        XCTAssertEqual(t?.ok, [.modell]); XCTAssertEqual(t?.ab, [.firmware, .anschluss])
    }
    func testFremdesModell_alleAbweichend_ausserZufallstreffer() {
        let t = teil("X", 1, .iscsiUnbekannt)
        XCTAssertEqual(t?.ok, []); XCTAssertEqual(t?.ab, [.modell, .firmware, .anschluss])
    }
    func testFormatieren_5CUSB_nichtErprobt_naechsterIstPro() {
        let t = teil("5C Gen3", 50532, .usb, .formatieren)
        XCTAssertEqual(t?.bester, "DroboPro"); XCTAssertEqual(t?.ok, []) // Pro/WLAN trifft weder Modell, Build noch USB
    }

    // Anschluss zur Laufzeit, Ermittler injiziert
    func testAnschlussNetz_WLAN_Kabel_Andere_KeineSchnittstelle() {
        func a(_ n: String?, _ art: SchnittstellenArt) -> Anschluss { anschlussNetz(host: "192.0.2.10", schnittstelle: { _ in n }, art: { _ in art }) }
        XCTAssertEqual(a("en0", .wlan), .iscsiWLAN)
        XCTAssertEqual(a("en5", .kabel), .iscsiKabel)
        XCTAssertEqual(a("utun3", .andere), .iscsiUnbekannt)
        XCTAssertEqual(a(nil, .wlan), .iscsiUnbekannt, "keine Schnittstelle im Teilnetz")
    }
    /// Sicherheitsbefund 2026-10-17: zwei Schnittstellen im selben Teilnetz (WLAN en0 + Kabel en8); die Route fuehrt ueber en8, die App meldete "WLAN" (erste Teilnetz-Uebereinstimmung).
    /// Echte Maschine, ohne Paket: `route -n get` (reine Routenabfrage) ist die Wahrheit, die App muss dieselbe Schnittstelle nennen.
    func testSchnittstelleZu_FolgtDerRoute_NichtDemErstenTeilnetzTreffer() throws {
        let host = "192.168.178.90"
        guard schnittstelleZu(host: "192.168.178.53") != nil || true, let aus = routeSchnittstelle(host) else { throw XCTSkip("kein route-Ergebnis") }
        XCTAssertEqual(schnittstelleZu(host: host), aus, "Route sagt \(aus)")
        XCTAssertNotEqual(schnittstelleZu(host: "127.0.0.1"), "en0"); XCTAssertEqual(anschlussNetz(host: "127.0.0.1"), .iscsiUnbekannt, "Loopback ist nie WLAN oder Kabel")
    }
    private func routeSchnittstelle(_ host: String) -> String? {
        let (rc, out) = ausfuehren("/sbin/route", ["-n", "get", host]); guard rc == 0 else { return nil }
        return out.split(separator: "\n").first { $0.contains("interface:") }.map { $0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces) }
    }
    func testQuelladresseZuSchnittstelle_ZweiSchnittstellenImSelbenTeilnetz() {
        let liste = [("en0", "192.168.178.53"), ("en8", "192.168.178.189"), ("lo0", "127.0.0.1")]
        XCTAssertEqual(schnittstelleFuerQuelle("192.168.178.189", liste), "en8")
        XCTAssertEqual(schnittstelleFuerQuelle("127.0.0.1", liste), "lo0")
        XCTAssertNil(schnittstelleFuerQuelle("10.9.9.9", liste))
        func a(_ q: String) -> Anschluss { anschlussNetz(host: "192.168.178.90", schnittstelle: { _ in schnittstelleFuerQuelle(q, liste) }, art: { $0 == "en0" ? .wlan : ($0 == "en8" ? .kabel : .andere) }) }
        XCTAssertEqual(a("192.168.178.189"), .iscsiKabel); XCTAssertEqual(a("127.0.0.1"), .iscsiUnbekannt); XCTAssertEqual(a("10.9.9.9"), .iscsiUnbekannt)
    }
    func testSchnittstelleZu_Loopback_UndUngueltigeAdresse() {
        XCTAssertEqual(schnittstelleZu(host: "127.0.0.1"), "lo0")
        XCTAssertNil(schnittstelleZu(host: "kein-host"))
        XCTAssertEqual(schnittstellenArt(bsd: "lo0"), .andere)
    }
}
