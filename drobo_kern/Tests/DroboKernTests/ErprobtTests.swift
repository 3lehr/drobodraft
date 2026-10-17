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
    func testProUeberKabel_NurGelesen_SchreibenUndFormatierenNichtErprobt() {
        XCTAssertTrue(nicht(e("Pro", 22137, .iscsiKabel, .schreiben)))
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
        XCTAssertEqual(s.map(\.anschluss), [.usb, .iscsiWLAN], "Kabel steht NICHT als erprobt zum Schreiben da")
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
    func testTeiltreffer_NurAnschlussAbweichend_Kabel() {
        let t = teil("Pro", 22137, .iscsiKabel)
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
    func testSchnittstelleZu_Loopback_UndUngueltigeAdresse() {
        XCTAssertEqual(schnittstelleZu(host: "127.0.0.1"), "lo0")
        XCTAssertNil(schnittstelleZu(host: "kein-host"))
        XCTAssertEqual(schnittstellenArt(bsd: "lo0"), .andere)
    }
}
