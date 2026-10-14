/// An Rohmessungen der Drobo 5C (2026-10-14, /dev/rdisk7s2, nur lesend) geeichtes Geraetemodell fuer den Pruefbau TEST_DROBO:
/// ein Geraet, das Befehle strikt nacheinander abarbeitet (Warteschlangentiefe bringt nichts); Zeit je Lesebefehl
/// 0,54 ms + Bytes / 253 MB/s, dazu 35 ms, wenn der Befehl nicht im Umkreis von 1 MiB um das Ende des vorigen beginnt.
/// Selbsttest: tools/drobo_modell_selbsttest.sh (1 MiB seriell ~ 224 MB/s, 128 KiB seriell ~ 123 MB/s, Rohmessung 214-224 bzw. 123 MB/s).
enum DroboModell {
    static let grundzeit = 0.00054, rate = 253e6, sprungzeit = 0.035, sprungSchwelle: Int64 = 1 << 20
    /// Sekunden fuer einen Lesebefehl ab `start` ueber `bytes`, wenn der vorige Befehl bei `vorigesEnde` endete.
    static func dauer(start: Int64, bytes: Int, vorigesEnde: Int64) -> Double {
        grundzeit + Double(bytes) / rate + (abs(start - vorigesEnde) > sprungSchwelle ? sprungzeit : 0)
    }
}
