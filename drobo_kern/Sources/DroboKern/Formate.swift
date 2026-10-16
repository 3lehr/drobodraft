import Foundation

// Datenraten fuer die Tempo-Tabelle "Reicht es? / Wie schnell?".
//
// QUELLE (einzige): Apple, "Apple ProRes" White Paper, April 2022, Dokumentnummer 028-00500-A,
//   Anhang "Target Data Rates" (Seiten 19-21), Spalte Mb/s. PDF: https://www.apple.com/cl/final-cut-pro/docs/Apple_ProRes.pdf
//   abgerufen 2026-10-16; Zahlen von dort abgeschrieben, ohne Alpha-Kanal (4444 / 4444 XQ "no alpha").
//   Bildraten der Tabelle: 24p, 25p, 30p, 50p, 60p (Apple fuehrt 30p/60p fuer 29,97/59,94 und 24p fuer 23,976/24).
//   Mb/s = 10^6 Bit/s, MB = 10^6 Byte (Apples GB/h-Spalte rechnet ebenso: 176 Mb/s = 79 GB/h).
//   "Target": ProRes ist VBR, die Datenrate weicht meist wenig ab, einzelne Bilder koennen bis ~10 % groesser sein.
// NICHT enthalten, weil nicht belegbar: Blackmagic RAW (Blackmagic veroeffentlicht die Raten nur als Bild/Rechner auf der Produktseite,
//   Stand 2026-10-16; Foren-/Blogwerte widersprechen sich), H.264/H.265 (Rate haengt vom Encoder ab, keine Herstellertabelle).

public let proResQuelle = "Apple ProRes White Paper, April 2022 (028-00500-A), Anhang Target Data Rates"

/// Spaltenreihenfolge der Zahlen in `ProResAufloesung.raten`.
public let proResCodecs = ["ProRes 422 Proxy", "ProRes 422 LT", "ProRes 422", "ProRes 422 HQ", "ProRes 4444", "ProRes 4444 XQ"]
public let proResBildraten = [24, 25, 30, 50, 60]

public struct ProResAufloesung: Equatable {
    public let breite: Int, hoehe: Int
    /// Bildrate -> Mb/s je Codec (Reihenfolge `proResCodecs`).
    public let raten: [Int: [Int]]
    public var name: String { "\(breite) x \(hoehe)" }

    /// Zielrate in Mb/s, nil wenn Format/Bildrate nicht in der Quelle steht.
    public func mbit(codec: Int, fps: Int) -> Int? { raten[fps].flatMap { codec < $0.count ? $0[codec] : nil } }
    /// Groesse eines Bildes in MB (10^6 Byte) = Mb/s / 8 / Bildrate.
    public func mbProBild(codec: Int, fps: Int) -> Double? { mbit(codec: codec, fps: fps).map { Double($0) / 8 / Double(fps) } }
    /// Hoechste Bildrate, die `mbProSekunde` traegt = MB/s / MB je Bild. Bezugszeile 60p (kleinster Rundungsfehler).
    public func maxBilder(mbProSekunde: Double, codec: Int, fps: Int = 60) -> Double? {
        mbProBild(codec: codec, fps: fps).map { maxBilderBerechnen(mbProSekunde: mbProSekunde, mbProBild: $0) }
    }
    /// Reicht die Rate fuer genau diese Bildrate (Tabellenwert der Bildrate selbst)?
    public func reicht(mbProSekunde: Double, codec: Int, fps: Int) -> Bool? {
        maxBilder(mbProSekunde: mbProSekunde, codec: codec, fps: fps).map { $0 >= Double(fps) }
    }
}

public func maxBilderBerechnen(mbProSekunde: Double, mbProBild: Double) -> Double { mbProBild > 0 ? mbProSekunde / mbProBild : 0 }

public let proResTabelle: [ProResAufloesung] = [
    ProResAufloesung(breite: 1920, hoehe: 1080, raten: [24: [36, 82, 117, 176, 264, 396], 25: [38, 85, 122, 184, 275, 413], 30: [45, 102, 147, 220, 330, 495], 50: [76, 170, 245, 367, 551, 826], 60: [91, 204, 293, 440, 660, 990]]),
    ProResAufloesung(breite: 2048, hoehe: 1080, raten: [24: [41, 93, 134, 201, 302, 453], 25: [43, 97, 140, 210, 315, 472], 30: [52, 116, 168, 251, 377, 566], 50: [86, 194, 280, 419, 629, 944], 60: [103, 232, 335, 503, 754, 1131]]),
    ProResAufloesung(breite: 3840, hoehe: 2160, raten: [24: [145, 328, 471, 707, 1061, 1591], 25: [151, 342, 492, 737, 1106, 1659], 30: [182, 410, 589, 884, 1326, 1989], 50: [303, 684, 983, 1475, 2212, 3318], 60: [363, 821, 1178, 1768, 2652, 3977]]),
    ProResAufloesung(breite: 4096, hoehe: 2160, raten: [24: [155, 350, 503, 754, 1131, 1697], 25: [162, 365, 524, 786, 1180, 1769], 30: [194, 437, 629, 943, 1414, 2121], 50: [323, 730, 1049, 1573, 2359, 3539], 60: [388, 875, 1257, 1886, 2828, 4242]]),
    ProResAufloesung(breite: 5120, hoehe: 2700, raten: [24: [243, 547, 786, 1178, 1768, 2652], 25: [253, 570, 819, 1229, 1843, 2765], 30: [304, 684, 982, 1473, 2210, 3314], 50: [507, 1140, 1638, 2458, 3686, 5530], 60: [608, 1367, 1964, 2946, 4419, 6629]]),
    ProResAufloesung(breite: 6144, hoehe: 3240, raten: [24: [350, 788, 1131, 1697, 2545, 3818], 25: [365, 821, 1180, 1769, 2654, 3981], 30: [437, 985, 1414, 2121, 3182, 4772], 50: [730, 1643, 2359, 3539, 5308, 7962], 60: [875, 1969, 2828, 4242, 6364, 9545]]),
    ProResAufloesung(breite: 8192, hoehe: 4320, raten: [24: [622, 1400, 2011, 3017, 4525, 6788], 25: [649, 1460, 2097, 3146, 4719, 7078], 30: [778, 1750, 2514, 3771, 5657, 8485], 50: [1298, 2920, 4194, 6291, 9437, 14156], 60: [1556, 3500, 5028, 7542, 11313, 16970]]),
]
