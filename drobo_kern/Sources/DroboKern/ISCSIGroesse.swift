import Foundation

/// LUN-Groesse der DroboPro aendern: GESPERRT. Die Aenderung ist ein 0xEA-Systembefehl; jeder solche Befehl loest an der DroboPro einen Neustart aus
/// (gemessen 2026-10-17, siehe `ISCSISitzung.verbot`). Wirft sofort, vor jedem Netzkontakt und jeder Dateiaktion.
public func iscsiLunGroesse() throws {
    throw ISCSIFehler.verboten("system commands to the DroboPro are blocked: they trigger a restart (measured 2026-10-17)")
}

/// EA-10-Systembefehl im Format des Dashboards (Ghidra-Dekompilat DDService64d 3.6.1, `ESASystemOperationRequest` @0x1000c56e4):
/// `EA 10 | Typ0 ? 0x80 : 0 | Op | Arg | 00 | 0x21 (FSEQ<<5|1) | Len BE16 | Ctl 0`, danach `daten` als Data-Out.
/// NUR BAUEN. Es gibt keinen Sendeweg: `ISCSISitzung.verbot` lehnt jedes 0xEA ab, ein Freischalten braucht eine Betreiberfreigabe je Op.
public struct EASysop: Equatable {
    public var cdb: [UInt8]; public var daten: [UInt8]; public var lesen: Int

    static func bauen(op: UInt8, arg: UInt8 = 0, daten: [UInt8] = [], lesen: Int = 0) -> EASysop {
        let n = lesen > 0 ? lesen : daten.count
        return EASysop(cdb: [0xEA, 0x10, lesen > 0 ? 0x80 : 0x00, op, arg, 0x00, 0x21, UInt8(n >> 8), UInt8(n & 0xFF), 0x00], daten: daten, lesen: lesen)
    }
    static func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    /// Op 0x0F `resizeLUNS` @0x1000a7f78: neue LUN-Groesse in TB (Bytefolge BE: Vermutung). Gerät startet danach neu, alle LUNs leer.
    public static func lunGroesse(txn: UInt8, tb: UInt32) -> EASysop { bauen(op: 0x0F, arg: txn, daten: be(tb)) }
    /// Op 0x12 `CreateLUN` @0x10006654e: u64 BE Groesse (Einheit unbelegt) · u8 Flags · 0 · u16 BE LUN-ID.
    public static func lunAnlegen(id: UInt16, groesse: UInt64, flags: UInt8) -> EASysop { bauen(op: 0x12, daten: be(groesse) + [flags, 0] + be(id)) }
    /// Op 0x13 `DeleteUniqueLUN` @0x100064008: u16 BE UniqueLUNID · u8 (ESABlockLUN+0x68) · 0.
    public static func lunLoeschen(id: UInt16, kennung: UInt8) -> EASysop { bauen(op: 0x13, daten: be(id) + [kennung, 0]) }
    /// Op 0x20 `getNextUniqueLUNID` @0x1000a901a: lesend, Antwort u16 BE.
    public static func naechsteLunID() -> EASysop { bauen(op: 0x20, lesen: 2) }
    /// Op 0x06 `identifyESA(Ej)` @0x1000a7f52: Len 4, Inhalt u32 (Bedeutung/Bytefolge: Vermutung).
    public static func identifizieren(txn: UInt8, wert: UInt32) -> EASysop { bauen(op: 0x06, arg: txn, daten: be(wert)) }
}
