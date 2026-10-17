import XCTest
@testable import DroboKern

final class ErprobtTests: XCTestCase {
    func nicht(_ e: ErprobtErgebnis) -> Bool { if case .nichtErprobt = e { return true }; return false }
    func e(_ m: String, _ b: Int?, _ a: Anschluss, _ x: ErprobtAktion) -> ErprobtErgebnis { erprobt(modell: m, build: b, anschluss: a, aktion: x) }

    func test5CSchreibenErprobt_FormatierenNicht() {
        XCTAssertEqual(e("5C Gen3", 50532, .usb, .schreiben), .erprobt)
        XCTAssertTrue(nicht(e("5C Gen3", 50532, .usb, .formatieren)), "5C: Formatieren nie gemessen")
    }
    func testProUeberWLAN_SchreibenUndFormatierenErprobt() {
        XCTAssertEqual(e("Pro", 22137, .iscsiWLAN, .schreiben), .erprobt)
        XCTAssertEqual(e("DroboPro", 22137, .iscsiWLAN, .formatieren), .erprobt)
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
        guard case .nichtErprobt(let l) = e("X", 1, .usb, .formatieren) else { return XCTFail() }
        XCTAssertEqual(l.map(\.anzeige), ["DroboPro"])
        guard case .nichtErprobt(let s) = e("X", 1, .usb, .schreiben) else { return XCTFail() }
        XCTAssertEqual(s.map(\.anschluss), [.usb, .iscsiWLAN], "Kabel steht NICHT als erprobt zum Schreiben da")
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
