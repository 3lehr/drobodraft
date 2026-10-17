import SwiftUI

// Schicht 1: Rohfarben stehen NUR hier. Sonst System- oder semantische Farben (.primary, .secondary, Color(nsColor: .windowBackgroundColor)).

enum Farbe {
    /// Gehaeuse des gezeichneten Geraets: bleibt dunkel, auch im hellen Modus (Abbild der Hardware).
    static let geraetGehaeuse = Color(white: 0.14)
    /// Blaue Fuellstands-LEDs wie am Geraet.
    static let fuellLed = Color(red: 0.30, green: 0.64, blue: 1.0)
}
