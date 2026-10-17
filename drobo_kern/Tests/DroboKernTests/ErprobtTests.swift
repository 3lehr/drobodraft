import XCTest
@testable import DroboKern

final class ErprobtTests: XCTestCase {
    func nicht(_ e: ErprobtErgebnis) -> Bool { if case .nichtErprobt = e { return true }; return false }

    func test5CSchreibenErprobt_FormatierenNicht() {
        XCTAssertEqual(erprobt(modell: "5C Gen3", build: 50532, aktion: .schreiben), .erprobt)
        XCTAssertTrue(nicht(erprobt(modell: "5C Gen3", build: 50532, aktion: .formatieren)), "5C: Formatieren nie gemessen")
    }
    func testProSchreibenUndFormatierenErprobt() {
        XCTAssertEqual(erprobt(modell: "Pro", build: 22137, aktion: .schreiben), .erprobt)
        XCTAssertEqual(erprobt(modell: "DroboPro", build: 22137, aktion: .formatieren), .erprobt)
    }
    func testBuildGrenze_MinusEins_PlusEins_Unbekannt() {
        for b in [22136, 22138] { XCTAssertTrue(nicht(erprobt(modell: "Pro", build: b, aktion: .schreiben)), "\(b)") }
        XCTAssertTrue(nicht(erprobt(modell: "Pro", build: nil, aktion: .schreiben)), "Firmware unbekannt")
    }
    func testFremdesModellUndKreuzung() {
        XCTAssertTrue(nicht(erprobt(modell: "5D", build: 50532, aktion: .schreiben)))
        XCTAssertTrue(nicht(erprobt(modell: "Pro", build: 50532, aktion: .schreiben)), "Build der 5C an der Pro ist nicht erprobt")
    }
    func testNichtErprobtNenntErprobteKombinationen() {
        guard case .nichtErprobt(let l) = erprobt(modell: "X", build: 1, aktion: .formatieren) else { return XCTFail() }
        XCTAssertEqual(l.map(\.anzeige), ["DroboPro"])
    }
}
