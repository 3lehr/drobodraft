import SwiftUI

// Schicht 1: Abstaende, Radien, Masse. Zahlen stehen NUR hier (Vorlage: wohlair_nativ/.../Tokens/Mass.swift).
// Erste Wahl bleibt der Systemabstand (.padding() ohne Wert, spacing weglassen); diese Tokens gelten, wo das System keinen Wert vorgibt.

enum Abstand {
    static let keiner: CGFloat = 0
    static let haar: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let rechteck: CGFloat = 4
    /// Einschub-Blende im Geraetebild.
    static let platte: CGFloat = 5
    static let klein: CGFloat = 8
    static let karte: CGFloat = 10
    static let geraet: CGFloat = 14
}

enum Mass {
    /// Blaetter (Sheets): frei skalierbar, nur Mindest- und Wunschbreite.
    static let blattMin: CGFloat = 380
    static let blattSchmal: CGFloat = 420
    static let blatt: CGFloat = 480
    static let blattBreit: CGFloat = 520
    static let popover: CGFloat = 300
    static let popoverMin: CGFloat = 240
    /// Fenster: kleinste brauchbare Groesse (Hauptfenster, Einstellungen, Hilfe).
    static let fensterBreiteMin: CGFloat = 760
    static let fensterHoeheMin: CGFloat = 520
    static let einstellungenBreiteMin: CGFloat = 560
    static let hilfeBreiteMin: CGFloat = 520
    static let seitenleisteMin: CGFloat = 200
    static let seitenleisteIdeal: CGFloat = 240
    /// Spalten in Listenzeilen (Mindestbreite, wachsen mit dem Text).
    static let schachtNr: CGFloat = 90
    static let lampeText: CGFloat = 110
    static let rolleAuswahl: CGFloat = 260
    /// Geraetebild (gezeichnete Vorderansicht).
    static let schachtBreite: CGFloat = 56
    static let schachtLuecke: CGFloat = 6
    static let geraetRand: CGFloat = 24
    static let geraetStapelBreite: CGFloat = 334
    static let plateStapelHoehe: CGFloat = 30
    static let plateSenkrechtBreite: CGFloat = 44
    static let plateSenkrechtHoehe: CGFloat = 150
    static let schachtNummerBreite: CGFloat = 16
    static let lampe: CGFloat = 22
    static let lampeWortHoehe: CGFloat = 28
    static let ledPunkt: CGFloat = 12
    /// Senkrechte Fuellstands-LEDs (DroboPro): kleiner, zehn Stueck uebereinander.
    static let ledPunktSenkrecht: CGFloat = 8
    static let ledLuecke: CGFloat = 4
    static let ledSpalte: CGFloat = 72
    static let aufteilungHoehe: CGFloat = 12
    /// Rundinstrument (Tempo).
    static let instrument: CGFloat = 190
    static let instrumentSkala: CGFloat = 150
    static let instrumentSchrift: CGFloat = 42
    static let bogenRand: CGFloat = 12
    static let bogenLinie: CGFloat = 16
    /// Deckkraft-Werte, die zur Farbe gehoeren.
    static let rahmenDeckkraft = 0.18
    static let auswahlDeckkraft = 0.28
    static let plakatDeckkraft = 0.25
}
